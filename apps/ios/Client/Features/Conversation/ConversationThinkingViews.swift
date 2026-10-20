import SwiftUI

struct ThinkingRow: View {
    private let singleLineHeight = ConversationTranscriptMetrics.thinkingRowHeight
    let trace: ThinkingTrace
    let sourceInvocations: [Invocation]
    let startedAt: Date
    let isLive: Bool
    var allowsLoader = true
    @Environment(ServiceManager.self) private var serviceManager

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
                            SourceChipButton(source: source) {
                                if let url = source.url {
                                    LinkOpener.open(url: url, serviceManager: serviceManager)
                                } else {
                                    isExpanded = true
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
                            if let url = source.url {
                                SourceChipButton(source: source) {
                                    open(url)
                                }
                            } else {
                                NavigationLink(value: invocation) {
                                    SourceChip(source: source)
                                }
                                .buttonStyle(.plain)
                                .frame(minHeight: Theme.Size.minimumTouchTarget)
                                .contentShape(Rectangle())
                                .accessibilityLabel(source.accessibilityLabel)
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

    private func open(_ url: URL) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            LinkOpener.open(url: url, serviceManager: serviceManager)
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

    var body: some View {
        HStack(spacing: 6) {
            switch source.icon {
            case .none:
                EmptyView()
            case .domain(let domain):
                DomainFavicon(domain: domain, size: 16)
            case .service(let service):
                ServiceAvatar(service: service, size: 20, shape: .roundedRect(4))
            }
            Text(source.label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.conversationSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .chipSurface(Theme.Colors.conversationSecondary.opacity(0.1))
    }
}

private struct SourceChipButton: View {
    let source: InvocationFormat.Source
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SourceChip(source: source)
        }
        .buttonStyle(.plain)
        .frame(minHeight: Theme.Size.minimumTouchTarget)
        .contentShape(Rectangle())
        .accessibilityLabel(source.accessibilityLabel)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                section(invocation.preview?.argumentsTruncated == true ? "Input preview" : "Input") {
                    Text(verbatim: invocation.name)
                        .font(Theme.Fonts.captionMd)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("conversation.invocation.function")
                    if invocation.preview?.argumentsTruncated == true { previewNotice }
                    inputValue
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
        }

        let label: String
        let icon: Icon
        let url: URL?
        let accessibilityLabel: String

        var id: String {
            switch icon {
            case .service(let service): "service:\(service.domain)"
            case .domain(let domain): "domain:\(url?.absoluteString ?? domain)"
            case .none: "label:\(label)"
            }
        }

        init(label: String, icon: Icon, url: URL? = nil, accessibilityLabel: String? = nil) {
            self.label = label
            self.icon = icon
            self.url = url
            self.accessibilityLabel = accessibilityLabel ?? label
        }
    }

    static func sources(_ invocation: Invocation, serviceManager: ServiceManager) -> [Source]? {
        let args = invocation.preview == nil ? invocation.args.objectValue : nil
        switch invocation.name {
        case Actions.webSearch:
            if let sources = searchSources(invocation), !sources.isEmpty {
                return sources
            }
            let query = invocation.sources?.query ?? args?["query"]?.stringValue ?? ""
            return query.isEmpty ? nil : [Source(label: query, icon: .none)]
        case Actions.webFetch:
            guard let source = fetchSource(invocation) else { return nil }
            return [source]
        case Actions.serviceFind:
            let query = invocation.sources?.query ?? args?["query"]?.stringValue ?? ""
            return query.isEmpty ? nil : [Source(label: query, icon: .none)]
        case Actions.serviceAttach, Actions.serviceValidate, Actions.serviceSignIn, Actions.serviceSolve, Actions.servicePayment, Actions.serviceDetach:
            guard let domain = invocation.sources?.domain ?? args?["domain"]?.stringValue, !domain.isEmpty else { return nil }
            let service = serviceManager.service(domain: domain)
            return [Source(label: service?.title ?? domain, icon: service.map(Source.Icon.service) ?? .none)]
        default:
            guard let domain = invokeDomain(invocation.name) else { return nil }
            let service = serviceManager.service(domain: domain)
            return [Source(label: service?.title ?? domain, icon: service.map(Source.Icon.service) ?? .none)]
        }
    }

    private static func searchSources(_ invocation: Invocation) -> [Source]? {
        if invocation.preview != nil {
            return (invocation.sources?.links ?? []).compactMap { link in
                guard let url = URL(string: link.url), let domain = domain(url) else { return nil }
                let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Source(label: domain, icon: .domain(domain), url: url,
                              accessibilityLabel: title.flatMap { $0.isEmpty ? nil : "\(domain), \($0)" })
            }
        }
        guard case .succeeded(let result?) = invocation.outcome,
              let items = result.objectValue?["items"]?.arrayValue else { return nil }
        return items.compactMap { item in
            guard let value = item.objectValue?["url"]?.stringValue,
                  let url = URL(string: value),
                  let domain = domain(url) else { return nil }
            let title = item.objectValue?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessibilityLabel = title.flatMap { $0.isEmpty ? nil : "\(domain), \($0)" }
            return Source(label: domain, icon: .domain(domain), url: url, accessibilityLabel: accessibilityLabel)
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
        return Source(label: domain, icon: .domain(domain), url: url)
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
