import SwiftUI

struct ThinkingRow: View {
    private let singleLineHeight = ConversationTranscriptMetrics.thinkingRowHeight
    let trace: ThinkingTrace
    let sourceInvocations: [Invocation]
    let startedAt: Date
    let isLive: Bool
    var allowsLoader = true
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.openConversation) private var openConversation

    private struct LiveAnimation {
        var label: String
        var pending: [String]
        var appearedAt: Date
        var lastAdvance: Date
        var sourceLive: Bool
    }
    private enum AnimationPhase {
        case settled(String)
        case live(LiveAnimation)

        var label: String {
            switch self {
            case .settled(let label): label
            case .live(let animation): animation.label
            }
        }

    }

    @State private var isExpanded = false
    @State private var seenEntries = 0
    @State private var animationPhase = AnimationPhase.settled("")
    @State private var animationTask: Task<Void, Never>?

    private var liveTargetLabel: String {
        if trace.completedAt != nil { return String(localized: "Plowing…") }
        guard let last = trace.entries.last else {
            return L10n.string("Plowing…")
        }
        return previewLabel(last)
    }

    private var settledTargetLabel: String {
        guard let last = trace.entries.last else {
            return ThinkingFormat.thoughtFor(startedAt, trace.completedAt)
        }
        if case .reasoning = last {
            return ThinkingFormat.thoughtFor(startedAt, trace.completedAt)
        }
        return previewLabel(last)
    }

    private var targetLabel: String { isLive ? liveTargetLabel : settledTargetLabel }
    private var sources: [InvocationFormat.Source] {
        guard !isLive else { return [] }
        var seen: Set<String> = []
        return sourceInvocations.flatMap {
            InvocationFormat.sources($0, serviceManager: serviceManager) ?? []
        }.filter { seen.insert($0.id).inserted }
    }
    private func previewLabel(_ entry: TraceEntry) -> String {
        switch entry {
        case let .reasoning(reasoning):
            return reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .invocation(invocation):
            return InvocationFormat.humanLabel(invocation)
        }
    }

    private var label: String { animationPhase.label.isEmpty ? targetLabel : animationPhase.label }
    private var showsLoader: Bool {
        isLive && label == L10n.string("Plowing…")
    }

    var body: some View {
        Group {
            if trace.isEmpty {
                rowHeader
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(A11yID.ConversationControls.activity)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Button { isExpanded = true } label: {
                        rowHeader
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                    if !sources.isEmpty {
                        SourceChipList(sources: sources) { source in
                            SourceChipButton(source: source, accessibilityIdentifier: "conversation.source.\(source.id)") {
                                if case .conversation(let id) = source.icon {
                                    openConversation?(id)
                                } else if let url = source.url {
                                    LinkOpener.open(url: url, serviceManager: serviceManager)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isExpanded) {
            ThinkingSheet(trace: trace, startedAt: startedAt)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.conversationSurface)
        }
        .animation(Theme.Animation.standard, value: isLive)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            let now = Date()
            if isLive {
                let labels = trace.entries.map(previewLabel)
                animationPhase = .live(LiveAnimation(
                    label: labels.first ?? liveTargetLabel,
                    pending: Array(labels.dropFirst()),
                    appearedAt: now,
                    lastAdvance: now,
                    sourceLive: true
                ))
                scheduleAnimation()
            } else {
                animationPhase = .settled(settledTargetLabel)
            }
            seenEntries = trace.entries.count
        }
        .onChange(of: trace.entries.count) { _, count in
            for entry in trace.entries.suffix(max(0, count - seenEntries)) {
                route(previewLabel(entry))
            }
            seenEntries = count
        }
        .onChange(of: targetLabel) { _, next in route(next) }
        .onChange(of: isLive) { _, live in transitionSource(to: live) }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
        }
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            if showsLoader {
                CellularAutomatonLoader.small
                    .frame(height: singleLineHeight)
                    .opacity(allowsLoader ? 1 : 0)
                    .accessibilityHidden(!allowsLoader)
                    .transition(.opacity)
            } else if !label.isEmpty {
                if isLive {
                    ShimmerText(text: AttributedString(label), lineLimit: 1)
                        .transition(.opacity)
                } else {
                    Text(label)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.conversationSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .transition(.opacity)
                }
            }
            if !isLive {
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.sm)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
                    .frame(height: singleLineHeight)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: singleLineHeight, alignment: .leading)
        .contentShape(
            Rectangle().inset(
                by: -(Theme.Size.minimumTouchTarget - singleLineHeight) / 2
            )
        )
    }

    private func route(_ next: String) {
        guard !next.isEmpty else { return }
        switch animationPhase {
        case .settled(let label):
            guard label != next else { return }
            withAnimation(Theme.Animation.quick) { animationPhase = .settled(next) }
        case .live(var animation):
            guard next != animation.label, next != animation.pending.last else { return }
            if animation.label == L10n.string("Plowing…"), animation.pending.isEmpty {
                withAnimation(Theme.Animation.quick) {
                    animation.label = next
                    animation.lastAdvance = Date()
                    animationPhase = .live(animation)
                }
                return
            }
            animation.pending.append(next)
            animationPhase = .live(animation)
            scheduleAnimation()
        }
    }

    private func transitionSource(to live: Bool) {
        switch animationPhase {
        case .settled(let label):
            guard live else { return }
            let now = Date()
            animationPhase = .live(LiveAnimation(
                label: label.isEmpty ? liveTargetLabel : label,
                pending: [],
                appearedAt: now,
                lastAdvance: now,
                sourceLive: true
            ))
        case .live(var animation):
            animation.sourceLive = live
            if !live { animation.pending.removeAll() }
            animationPhase = .live(animation)
            scheduleAnimation()
        }
    }

    private func scheduleAnimation() {
        guard animationTask == nil else { return }
        animationTask = Task { @MainActor in
            defer { animationTask = nil }
            while !Task.isCancelled {
                guard case .live(let snapshot) = animationPhase else { return }
                if !snapshot.pending.isEmpty {
                    let wait = Theme.Animation.sequenceHold - Date().timeIntervalSince(snapshot.lastAdvance)
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    guard !Task.isCancelled, case .live(var current) = animationPhase else { return }
                    guard !current.pending.isEmpty else { continue }
                    withAnimation(Theme.Animation.quick) {
                        current.label = current.pending.removeFirst()
                        current.lastAdvance = Date()
                        animationPhase = .live(current)
                    }
                    continue
                }
                guard !snapshot.sourceLive else { return }
                let minRemain = Theme.Animation.thinkingHold - Date().timeIntervalSince(snapshot.appearedAt)
                let seqRemain = Theme.Animation.sequenceHold - Date().timeIntervalSince(snapshot.lastAdvance)
                let wait = max(minRemain, seqRemain)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, case .live(let current) = animationPhase else { return }
                guard !current.sourceLive, current.pending.isEmpty else { continue }
                withAnimation(Theme.Animation.standard) {
                    animationPhase = .settled(settledTargetLabel)
                }
                return
            }
        }
    }
}

private struct ThinkingSheet: View {
    let trace: ThinkingTrace
    let startedAt: Date

    @State private var displayedEntries: [TraceEntry] = []
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let omitted = trace.omittedInvocations, omitted > 0 {
                        Text("Details omitted for \(omitted) additional Actions.")
                            .font(Theme.Fonts.captionMd)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Theme.Spacing.md)
                            .accessibilityIdentifier("conversation.trace.omitted")
                    }
                    ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { idx, entry in
                        TraceRow(entry: entry, isLast: idx == displayedEntries.count - 1)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.conversationSurface)
            .navigationTitle(Text("Steps", comment: "Title of the sheet showing the agent's reasoning and the actions it took."))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Invocation.self) { InvocationDetailView(invocation: $0) }
        }
        .onAppear { syncDisplayedEntries(immediate: true) }
        .onChange(of: trace.entries) { _, _ in syncDisplayedEntries(immediate: false) }
        .onDisappear { revealTask?.cancel() }
    }

    private func syncDisplayedEntries(immediate: Bool) {
        revealTask?.cancel()
        let incoming = trace.entries
        guard !immediate, !displayedEntries.isEmpty else {
            displayedEntries = incoming
            return
        }

        let displayedIds = Set(displayedEntries.map(\.id))
        var updated = displayedEntries
        for idx in updated.indices {
            if let latest = incoming.first(where: { $0.id == updated[idx].id }) {
                updated[idx] = latest
            }
        }
        withAnimation(Theme.Animation.quick) {
            displayedEntries = updated
        }

        let pending = incoming.filter { !displayedIds.contains($0.id) }
        guard !pending.isEmpty else { return }
        revealTask = Task { @MainActor in
            for entry in pending {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.Animation.standard) {
                    displayedEntries.append(entry)
                }
            }
        }
    }
}

private struct TraceRow: View {
    let entry: TraceEntry
    let isLast: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.openConversation) private var openConversation

    var body: some View {
        switch entry {
        case let .reasoning(reasoning):
            railed(node: { ReasoningNode() }) {
                SelectableText(
                    plain: reasoning.text,
                    font: MarkdownText.bodyFont,
                    color: Theme.Colors.conversationSecondary.uiColor,
                    lineSpacing: 1
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .invocation(invocation):
            railed(node: { InvocationNode(invocation: invocation) }) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    NavigationLink(value: invocation) {
                        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                            Text(InvocationFormat.humanLabel(invocation))
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .contentTransition(.opacity)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(Theme.Icons.sm)
                                .foregroundStyle(Theme.Colors.conversationSecondary)
                        }
                        .frame(minHeight: 22)
                        .contentShape(
                            Rectangle().inset(
                                by: -(Theme.Size.minimumTouchTarget - 22) / 2
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    if let sources = InvocationFormat.sources(invocation, serviceManager: serviceManager) {
                        SourceChipList(sources: sources) { source in
                            SourceChipButton(source: source, accessibilityIdentifier: "conversation.step.\(invocation.id).source.\(source.id)") {
                                open(source)
                            }
                        }
                    }
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: isLast ? Theme.Size.minimumTouchTarget : nil,
                    alignment: .topLeading
                )
                .animation(Theme.Animation.quick, value: invocation)
            }
            .accessibilityIdentifier(A11yID.ConversationControls.step(InvocationFormat.iconKind(invocation).rawValue))
        }
    }

    private func open(_ source: InvocationFormat.Source) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            if case .conversation(let id) = source.icon {
                openConversation?(id)
            } else if let url = source.url {
                LinkOpener.open(url: url, serviceManager: serviceManager)
            }
        }
    }

    private func railed<Node: View, Content: View>(
        @ViewBuilder node: () -> Node,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.xs) {
                node()
                if !isLast {
                    Rectangle()
                        .fill(Theme.Colors.conversationSecondary.dynamic.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, Theme.Spacing.xs)
                }
            }
            .frame(width: 22)
            content()
                .padding(.bottom, isLast ? 0 : Theme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ReasoningNode: View {
    var body: some View {
        Circle()
            .fill(Theme.Colors.conversationSecondary.dynamic.opacity(0.5))
            .frame(width: 8, height: 8)
            .frame(width: 22, height: 22)
    }
}

private struct InvocationNode: View {
    let invocation: Invocation

    private var tint: Color { invocation.isFailed ? Theme.Colors.error.dynamic : Theme.Colors.conversationSecondary.dynamic }

    var body: some View {
        Group {
            if invocation.isRunning {
                CellularAutomatonLoader(size: 14, tint: Theme.Colors.conversationSecondary.dynamic)
            } else {
                OxActionIcon(InvocationFormat.iconKind(invocation), size: 15)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 22, height: 22)
        .contentTransition(.opacity)
        .animation(Theme.Animation.quick, value: invocation)
    }
}

private struct SourceChip: View {
    let source: InvocationFormat.Source
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            switch source.icon {
            case .none:
                EmptyView()
            case .skill:
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.Colors.conversationSecondary)
                    .frame(width: 16, height: 20)
            case .file:
                Image(systemName: "doc")
                    .foregroundStyle(Theme.Colors.conversationSecondary)
                    .frame(width: 16, height: 20)
            case .conversation:
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Theme.Colors.conversationSecondary)
                    .frame(width: 16, height: 20)
            case .domain(let domain):
                DomainFavicon(domain: domain, size: 16)
            case .service(let service):
                ServiceAvatar(service: service, size: 20, shape: .roundedRect(4))
            }
            Text(label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.conversationSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .chipSurface(Theme.Colors.conversationSecondary.opacity(0.1))
    }
}

private struct SourceChipButton: View {
    let source: InvocationFormat.Source
    let accessibilityIdentifier: String
    let action: () -> Void

    private enum Destination: Identifiable {
        case file(String)
        case results(Invocation)
        case skill(Skill)
        case service(Service)

        var id: String {
            switch self {
            case .file(let path): "file:\(path)"
            case .results(let invocation): "results:\(invocation.id)"
            case .skill(let skill): "skill:\(skill.id)"
            case .service(let service): "service:\(service.domain)"
            }
        }
    }

    @State private var destination: Destination?
    @State private var profileID = StorageRoot.shared.activeId
    @State private var conversationTitle: String?

    var body: some View {
        Button {
            if let path = source.filePath {
                destination = .file(path)
            } else if let invocation = source.results {
                destination = .results(invocation)
            } else if let service = source.service {
                destination = .service(service)
            } else if let skill = source.skill {
                destination = .skill(skill)
            } else {
                action()
            }
        } label: {
            SourceChip(source: source, label: conversationTitle ?? source.label)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel(conversationTitle ?? source.accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .task(id: source.id) {
            conversationTitle = nil
            guard case .conversation(let id) = source.icon,
                  !OxClient.shared.conversations.summaries.contains(where: { $0.id == id }) else { return }
            let meta = await ProfileRepository.shared.conversationSummary(ConversationID(id), in: StorageRoot.shared.scope)
            guard !Task.isCancelled else { return }
            conversationTitle = meta?.displayTitle
        }
        .sheet(item: $destination) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .file(let path):
                        SourceFileView(path: path)
                    case .results(let invocation):
                        InvocationDetailView(invocation: invocation, outputOnly: true)
                    case .skill(let skill):
                        ConversationSkillDetails(skill: skill, skills: Skills.shared, profileID: profileID)
                    case .service(let service):
                        ServiceDetailView(initialService: service, primaryAction: nil, isAttached: false, onPrimaryAction: nil)
                            .presentationDetents([.medium, .large])
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        SheetDismissToolbarButton(accessibilityIdentifier: "conversation.source.close") {
                            self.destination = nil
                        }
                    }
                }
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.background)
        }
    }
}

private struct SourceFileView: View {
    let path: String
    @Environment(\.conversationFileResolver) private var resolver

    private enum Content {
        case loading
        case file(FileItem)
        case text(String, truncated: Bool)
        case failed(String)
    }

    @State private var content = Content.loading

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView()
            case .file(let file):
                if file.usesDedicatedPreview {
                    FileNavigationPage(file: file)
                } else {
                    FilePreviewPresentation(file: file)
                }
            case .text(let text, let truncated):
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        if truncated {
                            Text("This file preview was shortened.")
                                .font(Theme.Fonts.captionMd)
                                .foregroundStyle(.secondary)
                        }
                        CodeBlockView(code: text, accessibilityIdentifier: "conversation.source.file.content")
                    }
                    .padding(Theme.Spacing.lg)
                }
            case .failed(let message):
                ContentUnavailableView(message, systemImage: "doc.badge.ellipsis")
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            guard let resolver else {
                content = .failed(String(localized: "File unavailable."))
                return
            }
            if let file = await resolver.resolve(path) {
                content = .file(file)
                return
            }
            do {
                let result = try await resolver.read(path)
                guard let value = result.objectValue?["value"]?.objectValue,
                      let text = value["text"]?.stringValue else {
                    throw CocoaError(.fileReadUnknown)
                }
                try Task.checkCancellation()
                content = .text(text, truncated: value["truncated"]?.boolValue == true)
                Log.ui.info("SourceFileView.open disposition=text path=\(path)")
            } catch is CancellationError {
            } catch {
                content = .failed(error.localizedDescription)
                Log.ui.warning("SourceFileView.open disposition=failed path=\(path) error=\(error.localizedDescription)")
            }
        }
    }
}

private struct SourceChipList<Chip: View>: View {
    let sources: [InvocationFormat.Source]
    let chip: (InvocationFormat.Source) -> Chip

    init(
        sources: [InvocationFormat.Source],
        @ViewBuilder chip: @escaping (InvocationFormat.Source) -> Chip
    ) {
        self.sources = sources
        self.chip = chip
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(sources.indices, id: \.self) { index in
                    chip(sources[index])
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .scrollIndicators(.hidden)
        .excludesCompactPageSwitch()
    }
}

private enum ThinkingFormat {
    static func thoughtFor(_ startedAt: Date, _ completedAt: Date?) -> String {
        thoughtFor((completedAt ?? Date()).timeIntervalSince(startedAt))
    }

    static func thoughtFor(_ duration: TimeInterval) -> String {
        let secs = max(1, Int(duration.rounded()))
        if secs < 60 { return String(format: L10n.string("Thought for %lld seconds"), secs) }
        let m = secs / 60, s = secs % 60
        return String(format: L10n.string("Thought for %lld min %lld seconds"), m, s)
    }
}

private struct InvocationDetailView: View {
    let invocation: Invocation
    var outputOnly = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if !outputOnly {
                    section(invocation.preview?.argumentsTruncated == true ? "Input preview" : "Input") {
                        Text(verbatim: invocation.name)
                            .font(Theme.Fonts.captionMd)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("conversation.invocation.function")
                        if invocation.preview?.argumentsTruncated == true { previewNotice }
                        inputValue
                    }
                }
                section(invocation.preview?.resultTruncated == true ? "Output preview" : "Output") {
                    if invocation.preview?.resultTruncated == true { previewNotice }
                    outputValue
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.conversationSurface)
        .navigationTitle(InvocationFormat.humanLabel(invocation))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Fonts.captionMd)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inputValue: some View {
        if InvocationFormat.isEmpty(invocation.args) {
            if invocation.preview?.argumentsTruncated == true {
                Text("Input not retained.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(.secondary)
            } else {
                emptyValue
            }
        } else {
            CodeBlockView(code: InvocationFormat.clamp(InvocationFormat.prettyJSON(invocation.args)), accessibilityIdentifier: "invocation.\(invocation.id).input", language: "json")
        }
    }

    @ViewBuilder
    private var outputValue: some View {
        switch invocation.outcome {
        case let .succeeded(result?):
            CodeBlockView(code: InvocationFormat.clamp(InvocationFormat.prettyJSON(result)), accessibilityIdentifier: "invocation.\(invocation.id).output", language: "json")
        case .succeeded(nil):
            if invocation.preview?.resultTruncated == true {
                Text("Result not retained.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(.secondary)
            } else {
                emptyValue
            }
        case let .failed(error):
            CodeBlockView(code: InvocationFormat.clamp(error), accessibilityIdentifier: "invocation.\(invocation.id).error")
        case .running:
            HStack(spacing: Theme.Spacing.sm) {
                CellularAutomatonLoader.small
                Text("Running…", comment: "Shown in a step's detail while the action is still in flight.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.conversationSecondary)
            }
        }
    }

    private var previewNotice: some View {
        Text("This value was shortened or omitted. Its complete contents were not saved.")
            .font(Theme.Fonts.captionMd)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("conversation.invocation.previewNotice")
    }

    private var emptyValue: some View {
        Text("Empty", comment: "Placeholder for a step that took no input or produced no output.")
            .font(Theme.Fonts.bodySm)
            .foregroundStyle(Theme.Colors.conversationSecondary)
    }
}

private enum InvocationFormat {
    static func humanLabel(_ invocation: Invocation) -> String { invocation.purpose }

    private static func displayName(_ name: String) -> String {
        let prefix = "ox.service.invoke("
        if name.hasPrefix(prefix), name.hasSuffix(")") {
            return String(name.dropFirst(prefix.count).dropLast())
        }
        return name
    }

    static func iconKind(_ invocation: Invocation) -> OxActionIconKind {
        OxActionIconKind(actionName: invocation.name)
    }

    struct Source {
        enum Icon {
            case none
            case domain(String)
            case service(Service)
            case file(String)
            case conversation(UUID)
            case skill(Skill)
        }

        let label: String
        let icon: Icon
        let url: URL?
        let accessibilityLabel: String
        let results: Invocation?

        var filePath: String? {
            if case .file(let path) = icon { return path }
            return nil
        }

        var service: Service? {
            if case .service(let service) = icon { return service }
            return nil
        }

        var skill: Skill? {
            if case .skill(let skill) = icon { return skill }
            return nil
        }

        var id: String {
            switch icon {
            case .service(let service): "service:\(service.domain)"
            case .domain(let domain): "domain:\(url?.absoluteString ?? domain)"
            case .none: "results:\(results?.id.uuidString ?? label)"
            case .file(let path): "file:\(path)"
            case .conversation(let id): "conversation:\(id.uuidString)"
            case .skill(let skill): "skill:\(skill.id)"
            }
        }

        init(label: String, icon: Icon, url: URL? = nil, accessibilityLabel: String? = nil, results: Invocation? = nil) {
            self.label = label
            self.icon = icon
            self.url = url
            self.accessibilityLabel = accessibilityLabel ?? label
            self.results = results
        }
    }

    static func sources(_ invocation: Invocation, serviceManager: ServiceManager) -> [Source]? {
        let args = invocation.preview == nil ? invocation.args.objectValue : nil
        switch invocation.name {
        case Actions.fsRead, Actions.fsWrite, Actions.fsEdit:
            guard let path = invocation.args.objectValue?["path"]?.stringValue,
                  !path.isEmpty else { return nil }
            let parts = path.split(separator: "/")
            if parts.count >= 2, ["history", "conversations"].contains(parts[0]) {
                let id: UUID? = if let uuid = UUID(uuidString: String(parts[1])) {
                    uuid
                } else if let number = Int(parts[1]), number >= 0, let profileID = StorageRoot.shared.scope.profileID {
                    DurableConversationReference(profileID: profileID, conversationID: number).compatibilityID.rawValue
                } else {
                    nil
                }
                if let id {
                    let title = OxClient.shared.conversations.summaries.first { $0.id == id }?.displayTitle
                        ?? String(localized: "Conversation")
                    return [Source(label: title, icon: .conversation(id))]
                }
            }
            if parts.count >= 3, parts[0] == "skills",
               let skill = Skills.shared.skill(named: String(parts[1])) {
                guard skill.owner != .system else { return nil }
                if invocation.name == Actions.fsRead, parts.count == 3, parts[2] == "SKILL.md" {
                    return [Source(label: "/\(skill.displayName)", icon: .skill(skill), accessibilityLabel: "/\(skill.displayName), \(skill.description)")]
                }
            }
            return [Source(label: (path as NSString).lastPathComponent, icon: .file(path), accessibilityLabel: path)]
        case Actions.webSearch:
            if let sources = searchSources(invocation), !sources.isEmpty {
                return sources
            }
            let query = invocation.sources?.query ?? args?["query"]?.stringValue ?? ""
            return query.isEmpty ? nil : [Source(label: query, icon: .none, results: invocation)]
        case Actions.webFetch:
            guard let source = fetchSource(invocation) else { return nil }
            return [source]
        case Actions.serviceFind:
            let query = invocation.sources?.query ?? args?["query"]?.stringValue ?? ""
            return query.isEmpty ? nil : [Source(label: query, icon: .none, results: invocation)]
        case Actions.serviceAttach, Actions.serviceValidate, Actions.serviceSignIn, Actions.serviceSolve, Actions.servicePayment, Actions.serviceDetach:
            guard let domain = invocation.sources?.domain ?? args?["domain"]?.stringValue, !domain.isEmpty else { return nil }
            let service = serviceManager.service(domain: domain)
            return [Source(label: service?.title ?? domain, icon: service.map(Source.Icon.service) ?? .none, results: service == nil ? invocation : nil)]
        default:
            guard let domain = invokeDomain(invocation.name) else { return nil }
            let service = serviceManager.service(domain: domain)
            return [Source(label: service?.title ?? domain, icon: service.map(Source.Icon.service) ?? .none, results: service == nil ? invocation : nil)]
        }
    }

    private static func searchSources(_ invocation: Invocation) -> [Source]? {
        if invocation.preview != nil {
            return (invocation.sources?.links ?? []).compactMap { link in
                guard let url = URL(string: link.url), let domain = domain(url) else { return nil }
                return webSource(url: url, domain: domain, title: link.title)
            }
        }
        guard case .succeeded(let result?) = invocation.outcome,
              let items = result.objectValue?["items"]?.arrayValue else { return nil }
        return items.compactMap { item in
            guard let value = item.objectValue?["url"]?.stringValue,
                  let url = URL(string: value),
                  let domain = domain(url) else { return nil }
            return webSource(url: url, domain: domain, title: item.objectValue?["title"]?.stringValue)
        }
    }

    private static func fetchSource(_ invocation: Invocation) -> Source? {
        let argsURL = invocation.preview == nil ? invocation.args.objectValue?["url"]?.stringValue : invocation.sources?.links.first?.url
        let finalURL: String? = if invocation.preview == nil, case .succeeded(let result?) = invocation.outcome {
            result.objectValue?["url"]?.stringValue
        } else {
            nil
        }
        guard let value = finalURL ?? argsURL,
              let url = URL(string: value),
              let domain = domain(url) else { return nil }
        return webSource(url: url, domain: domain, title: invocation.sources?.links.first?.title)
    }

    private static func webSource(url: URL, domain: String, title: String?) -> Source {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.flatMap { $0.isEmpty ? nil : $0 } ?? domain
        return Source(label: label, icon: .domain(domain), url: url,
                      accessibilityLabel: label == domain ? domain : "\(domain), \(label)")
    }

    private static func domain(_ url: URL) -> String? {
        guard let domain = url.host(percentEncoded: false)?.lowercased(),
              !domain.isEmpty else { return nil }
        return domain
    }

    private static func invokeDomain(_ name: String) -> String? {
        let qualified = displayName(name)
        guard qualified != name else { return nil }
        let parts = qualified.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return parts[0] == "ios" ? "ios:\(parts[1])" : parts[1]
    }

    static func isEmpty(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .object(let o): return o.isEmpty
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    static func clamp(_ code: String, maxLines: Int = 60, maxChars: Int = 4000) -> String {
        var text = code
        var truncated = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            text = lines.prefix(maxLines).joined(separator: "\n")
            truncated = true
        }
        if text.count > maxChars {
            text = String(text.prefix(maxChars))
            truncated = true
        }
        return truncated ? text + "\n…" : text
    }

    static func prettyJSON(_ v: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(v),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]),
              let str = String(data: pretty, encoding: .utf8) else {
            return String(describing: v)
        }
        return str
    }
}
