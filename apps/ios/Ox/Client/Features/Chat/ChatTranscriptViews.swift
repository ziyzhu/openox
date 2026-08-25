import SwiftUI
import AVFAudio
import Observation

@MainActor
@Observable
final class MessageSpeechPlayback: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private(set) var speakingBlockID: UUID?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let audioSession = AVAudioSession.sharedInstance()
    @ObservationIgnored private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(text: String, blockID: UUID) {
        if speakingBlockID == blockID {
            stop(reason: "toggle")
            return
        }

        stop(reason: "replacement")
        let rendered = (try? AttributedString(markdown: text)).map { String($0.characters) } ?? text
        let spoken = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: spoken)
        let voice = SpeechVoiceSettings.shared.preferredVoice(for: AppLocale.shared.locale)
        utterance.voice = voice
        guard activateAudioSession() else { return }
        activeUtterance = utterance
        speakingBlockID = blockID
        Log.ui.info("MessageSpeech.start block=\(blockID) chars=\(spoken.count) voice=\(voice?.identifier ?? "default") quality=\(voice?.quality.rawValue ?? 0)")
        synthesizer.speak(utterance)
    }

    func stop(reason: String) {
        guard let blockID = speakingBlockID else { return }
        activeUtterance = nil
        speakingBlockID = nil
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession(reason: reason)
        Log.ui.info("MessageSpeech.stop block=\(blockID) reason=\(reason)")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance, outcome: "finished")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance, outcome: "canceled")
    }

    private func finish(_ utterance: AVSpeechUtterance, outcome: String) {
        guard activeUtterance === utterance, let blockID = speakingBlockID else { return }
        activeUtterance = nil
        speakingBlockID = nil
        deactivateAudioSession(reason: outcome)
        Log.ui.info("MessageSpeech.\(outcome) block=\(blockID)")
    }

    private func activateAudioSession() -> Bool {
        do {
            try audioSession.setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try audioSession.setActive(true)
            let route = audioSession.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            Log.ui.info("MessageSpeech.audioSession activated category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) route=\(route)")
            return true
        } catch {
            Log.ui.error("MessageSpeech.audioSession activation failed error=\(error.localizedDescription)")
            return false
        }
    }

    private func deactivateAudioSession(reason: String) {
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            Log.ui.info("MessageSpeech.audioSession deactivated reason=\(reason)")
        } catch {
            Log.ui.error("MessageSpeech.audioSession deactivation failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

}

private struct AttachmentThumb: View {
    let attachment: Artifact
    let sourceID: String
    let onOpen: (Artifact, String) -> Void

    var body: some View {
        ArtifactThumbnail(
            attachment: attachment,
            style: .transcript,
            previewSourceID: sourceID
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onOpen(attachment, sourceID) }
        .accessibilityAddTraits(.isButton)
    }
}

private struct ChatArtifactRow: View {
    let artifact: Artifact
    var previewSourceID: String? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if artifact.exists {
                ArtifactThumbnail(
                    attachment: artifact,
                    style: .row,
                    previewSourceID: previewSourceID
                )
            } else {
                Image(systemName: "trash")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .frame(width: 44, height: 44)
                    .background(Theme.Colors.background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(artifact.userFacingName)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(artifact.exists ? Theme.Colors.onSurface : Theme.Colors.onSurfaceMuted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let typeName = artifact.userFacingTypeName, artifact.exists {
                    Text(typeName)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                } else if !artifact.exists {
                    Text("Deleted artifact")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            if artifact.exists {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ServiceInspectorRow: View {
    let link: ServiceInspectorLink
    let chatID: UUID
    @Environment(ServiceManager.self) private var serviceManager
    @State private var isPresented = false

    private var service: Service? { serviceManager.service(domain: link.domain) }
    private var canInspect: Bool {
        guard let service else { return false }
        guard service.domain == "ios:browser" else { return true }
        return serviceManager.browserActionSessions.existingSession(for: chatID, service: service) != nil
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let service {
                ServiceAvatar(service: service, size: 44, shape: .roundedRect(Theme.Radius.sm), monogramSize: 20)
            } else {
                Image(systemName: "safari")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .frame(width: 44, height: 44)
                    .background(Theme.Colors.background, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(link.serviceName)
                    .font(Theme.Fonts.title)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !canInspect {
                    Text("Page unavailable")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                } else {
                    Text("View live page")
                        .font(Theme.Fonts.bodySm)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            Image(systemName: "safari")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture { isPresented = canInspect }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isPresented = canInspect }
        .accessibilityLabel("View \(link.serviceName) live page")
        .accessibilityIdentifier(A11yID.Chat.Message.serviceInspector(link.domain))
        .fullScreenCover(isPresented: $isPresented) {
            if let service {
                NavigationStack {
                    ServicePageInspector(service: service, browserSessionID: chatID)
                }
            }
        }
    }
}

struct ActivityBubble: View {
    private let label = L10n.string("Plowing…")

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader.small
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityIdentifier(A11yID.Chat.activity)
    }
}

private struct ThinkingRow: View {
    private let singleLineHeight: CGFloat = 22
    let trace: ThinkingTrace
    let startedAt: Date
    let isActive: Bool
    let continuesThinking: Bool

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

        var showsLive: Bool {
            if case .live = self { true } else { false }
        }
    }

    @State private var isExpanded = false
    @State private var seenEntries = 0
    @State private var animationPhase = AnimationPhase.settled("")
    @State private var animationTask: Task<Void, Never>?

    private var isLive: Bool { isActive && (trace.completedAt == nil || continuesThinking) }
    private var showsLive: Bool { animationPhase.showsLive }
    private var rendersLive: Bool { showsLive || (isLive && animationPhase.label.isEmpty) }
    private var hasError: Bool {
        if case let .invocation(invocation) = trace.entries.last { return invocation.isFailed }
        return false
    }

    private var liveTargetLabel: String {
        if continuesThinking, trace.completedAt != nil { return String(localized: "Plowing…") }
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

    private var targetLabel: String { rendersLive ? liveTargetLabel : settledTargetLabel }

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
        rendersLive && !hasError && label == L10n.string("Plowing…")
    }

    var body: some View {
        Group {
            if trace.isEmpty {
                rowContent
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier(A11yID.Chat.activity)
            } else {
                Button { isExpanded = true } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
        }
        .sheet(isPresented: $isExpanded) {
            ThinkingSheet(trace: trace, startedAt: startedAt)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.background)
        }
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

    private var rowContent: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            if showsLoader {
                CellularAutomatonLoader.small
                    .frame(height: singleLineHeight)
                    .transition(.opacity)
            } else if !label.isEmpty {
                if rendersLive, !hasError {
                    ShimmerText(text: AttributedString(label))
                        .transition(.opacity)
                } else {
                    Text(label)
                        .font(Theme.Fonts.bodyMd)
                        .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .transition(.opacity)
                }
            }
            if !rendersLive {
                Image(systemName: "chevron.right")
                    .font(Theme.Icons.sm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    .frame(height: singleLineHeight)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: Theme.Animation.standard), value: rendersLive)
        .frame(maxWidth: .infinity, minHeight: singleLineHeight, alignment: .leading)
        .padding(.vertical, (Theme.Size.minimumTouchTarget - singleLineHeight) / 2)
        .contentShape(Rectangle())
    }

    private func route(_ next: String) {
        guard !next.isEmpty else { return }
        switch animationPhase {
        case .settled(let label):
            guard label != next else { return }
            withAnimation(.easeInOut(duration: 0.16)) { animationPhase = .settled(next) }
        case .live(var animation):
            guard next != animation.label, next != animation.pending.last else { return }
            if animation.label == L10n.string("Plowing…"), animation.pending.isEmpty {
                withAnimation(.easeInOut(duration: 0.16)) {
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
                    withAnimation(.easeInOut(duration: 0.16)) {
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
                withAnimation(.easeOut(duration: Theme.Animation.standard)) {
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
                    ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { idx, entry in
                        TraceRow(entry: entry, isLast: idx == displayedEntries.count - 1)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Colors.background)
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
        withAnimation(.easeInOut(duration: 0.16)) {
            displayedEntries = updated
        }

        let pending = incoming.filter { !displayedIds.contains($0.id) }
        guard !pending.isEmpty else { return }
        revealTask = Task { @MainActor in
            for entry in pending {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    displayedEntries.append(entry)
                }
            }
        }
    }
}

private struct TraceRow: View {
    let entry: TraceEntry
    let isLast: Bool
    @Environment(ServiceManager.self) private var serviceManager

    var body: some View {
        switch entry {
        case let .reasoning(reasoning):
            railed(node: { ReasoningNode() }) {
                SelectableText(
                    plain: reasoning.text,
                    font: MarkdownText.bodyFont,
                    color: Theme.Colors.onSurfaceMuted.uiColor,
                    lineSpacing: 1
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .invocation(invocation):
            NavigationLink(value: invocation) {
                railed(node: { InvocationNode(invocation: invocation) }) {
                    HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(InvocationFormat.humanLabel(invocation))
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .lineLimit(3)
                                .truncationMode(.tail)
                                .contentTransition(.opacity)
                            if let source = InvocationFormat.source(invocation, serviceManager: serviceManager) {
                                SourceChip(source: source)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(Theme.Icons.sm)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                    .frame(minHeight: 22)
                    .animation(.easeInOut(duration: 0.16), value: invocation)
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: Theme.Size.minimumTouchTarget, alignment: .top)
            .contentShape(Rectangle())
            .accessibilityIdentifier(A11yID.Chat.step(InvocationFormat.iconKind(invocation).rawValue))
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
                        .fill(Theme.Colors.onSurfaceMuted.dynamic.opacity(0.25))
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
            .fill(Theme.Colors.onSurfaceMuted.dynamic.opacity(0.5))
            .frame(width: 8, height: 8)
            .frame(width: 22, height: 22)
    }
}

private struct InvocationNode: View {
    let invocation: Invocation

    private var tint: Color { invocation.isFailed ? Theme.Colors.error.dynamic : Theme.Colors.onSurfaceMuted.dynamic }

    var body: some View {
        Group {
            if invocation.isRunning {
                CellularAutomatonLoader(size: 14, tint: Theme.Colors.onSurfaceMuted.dynamic)
            } else {
                OxActionIcon(InvocationFormat.iconKind(invocation), size: 15)
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 22, height: 22)
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.16), value: invocation)
    }
}

private struct SourceChip: View {
    let source: InvocationFormat.Source

    var body: some View {
        HStack(spacing: 6) {
            if let service = source.service {
                ServiceAvatar(service: service, size: 20, shape: .roundedRect(4), monogramSize: 11)
            }
            Text(source.label)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .chipSurface(Theme.Colors.onSurfaceMuted.opacity(0.1))
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
                section("Input") { inputValue }
                section("Output") { outputValue }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.background)
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
            emptyValue
        } else {
            CodeBlockView(code: InvocationFormat.clamp(InvocationFormat.prettyJSON(invocation.args)), language: "json")
        }
    }

    @ViewBuilder
    private var outputValue: some View {
        switch invocation.outcome {
        case let .succeeded(result?):
            CodeBlockView(code: InvocationFormat.clamp(InvocationFormat.prettyJSON(result)), language: "json")
        case .succeeded(nil):
            emptyValue
        case let .failed(error):
            CodeBlockView(code: InvocationFormat.clamp(error))
        case .running:
            HStack(spacing: Theme.Spacing.sm) {
                CellularAutomatonLoader.small
                Text("Running…", comment: "Shown in a step's detail while the action is still in flight.")
                    .font(Theme.Fonts.bodySm)
                    .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
        }
    }

    private var emptyValue: some View {
        Text("Empty", comment: "Placeholder for a step that took no input or produced no output.")
            .font(Theme.Fonts.bodySm)
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
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
        let label: String
        let service: Service?
    }

    static func source(_ invocation: Invocation, serviceManager: ServiceManager) -> Source? {
        let args = invocation.args.objectValue
        switch InvocationName(rawValue: invocation.name) {
        case .serviceFind:
            let query = args?["query"]?.stringValue ?? ""
            return query.isEmpty ? nil : Source(label: query, service: nil)
        case .serviceAttach, .serviceSignIn, .serviceSolve, .servicePayment, .serviceDetach:
            guard let domain = args?["domain"]?.stringValue, !domain.isEmpty else { return nil }
            let service = serviceManager.service(domain: domain)
            return Source(label: service?.title ?? domain, service: service)
        default:
            guard let domain = invokeDomain(invocation.name) else { return nil }
            let service = serviceManager.service(domain: domain)
            return Source(label: service?.title ?? domain, service: service)
        }
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

struct EditTarget: Identifiable {
    let id: UUID
}

struct EditMessageView: View {
    @Binding var draft: String
    let iconButtonSize: CGFloat
    let composerButtonSize: CGFloat
    let onCancel: () -> Void
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private var empty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Edit message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .accessibilityIdentifier(A11yID.Chat.input)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .padding(.leading, Theme.Spacing.lg)
                    .padding(.trailing, empty ? Theme.Spacing.lg : 6)
                    .padding(.vertical, 12)

                if !empty {
                    Button {
                        Haptics.impact(.send)
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(.subheadline, weight: .bold))
                            .foregroundStyle(Theme.Colors.onPrimary)
                            .frame(width: composerButtonSize, height: composerButtonSize)
                            .background(Theme.Colors.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .accessibilityLabel(A11yLabel.send)
                    .accessibilityIdentifier(A11yID.Chat.send)
                }
            }
            .background {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Colors.chatSurface)
        .onAppear {
            #if targetEnvironment(simulator)
            let draft = $draft
            DebugUIAPI.setEditDraft = { draft.wrappedValue = $0 }
            #endif
        }
        .onDisappear {
            #if targetEnvironment(simulator)
            DebugUIAPI.setEditDraft = nil
            #endif
        }
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
            Log.ui.info("EditMessage.focus requested")
        }
        .onChange(of: focused) { _, value in
            Log.ui.info("EditMessage.focus changed=\(value)")
        }
    }

    private var header: some View {
        ZStack {
            Text("Edit message", comment: "Title of the screen for editing a previously sent message before resending it.")
                .font(Theme.Fonts.labelMd)
                .foregroundStyle(Theme.Colors.onSurface)
            HStack {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.title3, weight: .medium))
                        .foregroundStyle(Theme.Colors.onSurface)
                        .frame(width: iconButtonSize, height: iconButtonSize)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(L10n.string("Cancel editing", comment: "Accessibility label for the button that closes the edit-message screen without resending."))
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

struct MessageControls {
    let onCopy: (String) -> Void
    let isCopied: Bool
    let onReadAloud: (String) -> Void
    let isSpeaking: Bool
    let canMutate: Bool
    let onBranch: () -> Void
    let onRetry: () -> Void
    let onEdit: () -> Void
}

struct ArtifactControls {
    let revision: Int
    let canMutate: Bool
    let onRename: (Artifact) -> Void
    let onDelete: (Artifact) -> Void
}

private struct UserBubble: View {
    let text: String
    let attachments: [Artifact]
    let sourcePrefix: String
    let onOpenAttachment: (Artifact, String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if attachments.count == 1 {
                attachmentThumb(at: 0)
            } else if attachments.count > 1 {
                Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(stride(from: 0, to: attachments.count, by: 2)), id: \.self) { index in
                        GridRow {
                            attachmentThumb(at: index)
                            if index + 1 < attachments.count {
                                attachmentThumb(at: index + 1)
                            }
                        }
                    }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(Theme.Fonts.bodyMd)
                    .foregroundStyle(Theme.Colors.onSurface)
                    // Body font metrics add vertical whitespace around glyphs, so 12 pt reads like 14 pt horizontally.
                    .padding(.horizontal, 14)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.Colors.bubble, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            }
        }
    }

    private func attachmentThumb(at index: Int) -> some View {
        let attachment = attachments[index]
        return AttachmentThumb(
            attachment: attachment,
            sourceID: "\(sourcePrefix):\(index):\(attachment.id)",
            onOpen: onOpenAttachment
        )
    }
}

private struct UserSkillBubble: View {
    let invocation: UserSkillInvocation
    let attachments: [Artifact]
    let sourcePrefix: String
    let onOpenAttachment: (Artifact, String) -> Void
    let onOpenSkill: (Skill) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button { onOpenSkill(invocation.skill) } label: {
                SkillLibraryRow(skill: invocation.skill)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("/\(invocation.skill.displayName), \(invocation.skill.description)")
            .accessibilityIdentifier(A11yID.Chat.Message.skill(invocation.skill.name))

            if !invocation.argument.isEmpty || !attachments.isEmpty {
                UserBubble(
                    text: invocation.argument,
                    attachments: attachments,
                    sourcePrefix: sourcePrefix,
                    onOpenAttachment: onOpenAttachment
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.Chat.Message.user)
            }
        }
    }
}

struct QueuedBubble: View {
    let message: Chat.QueuedMessage
    let onOpenAttachment: (Artifact, String) -> Void
    let onOpenSkill: (Skill) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 40)
                if let invocation = message.skillInvocation {
                    UserSkillBubble(
                        invocation: invocation,
                        attachments: message.attachments,
                        sourcePrefix: "queued:\(message.id.uuidString)",
                        onOpenAttachment: onOpenAttachment,
                        onOpenSkill: onOpenSkill
                    )
                    .opacity(0.55)
                } else {
                    UserBubble(
                        text: message.text,
                        attachments: message.attachments,
                        sourcePrefix: "queued:\(message.id.uuidString)",
                        onOpenAttachment: onOpenAttachment
                    )
                    .opacity(0.55)
                }
            }
            Button {
                Haptics.impact(.queuedMessageCancelled)
                onCancel()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text("Queued", comment: "Tag on a chat message the user sent while the agent was still working; it is delivered when the current turn finishes. Tapping cancels it.")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel(L10n.string("Cancel queued message", comment: "Accessibility label for the button that cancels a message queued while the agent is working."))
        }
        .accessibilityElement(children: message.skillInvocation == nil ? .combine : .contain)
        .accessibilityIdentifier(A11yID.Chat.Message.user)
    }
}

struct BlockView: View, Equatable {
    let block: ChatBlock
    let isStreamingTail: Bool
    let chatID: UUID
    let continuesThinking: Bool
    let controls: MessageControls
    let artifactControls: ArtifactControls
    let onOpenAttachment: (Artifact, String) -> Void
    let onOpenSkill: (Skill) -> Void
    let onOpenLink: (URL) -> Void
    @State private var hasStreamed = false

    static func == (lhs: BlockView, rhs: BlockView) -> Bool {
        lhs.block == rhs.block
            && lhs.isStreamingTail == rhs.isStreamingTail
            && lhs.continuesThinking == rhs.continuesThinking
            && lhs.controls.isCopied == rhs.controls.isCopied
            && lhs.controls.isSpeaking == rhs.controls.isSpeaking
            && lhs.controls.canMutate == rhs.controls.canMutate
            && lhs.artifactControls.revision == rhs.artifactControls.revision
            && lhs.artifactControls.canMutate == rhs.artifactControls.canMutate
    }

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .userText(let s, let atts):
            userTextBubble(s, attachments: atts, createdAt: block.createdAt)
        case .userSkill(let invocation, let atts):
            userSkillBubble(invocation, attachments: atts, createdAt: block.createdAt)
        case .agentContent(let item):
            agentContentBubble([item])
        case let .thinking(trace):
            ThinkingRow(
                trace: trace,
                startedAt: block.createdAt,
                isActive: isStreamingTail,
                continuesThinking: continuesThinking
            )
            .padding(.horizontal, 4)
        case .contextCompaction:
            contextCompactionDivider
        case .responseFooter:
            EmptyView()
        }
    }

    private var contextCompactionDivider: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Rectangle()
                .fill(Theme.Colors.onSurfaceMuted.opacity(0.2))
                .frame(height: 1)
            Label {
                Text("Context compacted", comment: "Divider shown in a chat where earlier model context was summarized.")
            } icon: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .fixedSize()
            Rectangle()
                .fill(Theme.Colors.onSurfaceMuted.opacity(0.2))
                .frame(height: 1)
        }
        .font(Theme.Fonts.caption)
        .foregroundStyle(Theme.Colors.onSurfaceMuted)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Context compacted", comment: "Accessibility label for the context-compaction divider in a chat."))
        .accessibilityIdentifier(A11yID.Chat.Message.contextCompaction)
    }

    private func userTextBubble(_ text: String, attachments: [Artifact], createdAt: Date) -> some View {
        HStack {
            Spacer(minLength: 40)
            UserBubble(
                text: text,
                attachments: attachments,
                sourcePrefix: "block:\(block.id.uuidString)",
                onOpenAttachment: onOpenAttachment
            )
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
                .contextMenu {
                    Section(Self.timestampFormatter.string(from: createdAt)) {
                        Button {
                            controls.onCopy(text)
                        } label: {
                            Label(L10n.string("Copy", comment: "Context menu action on a sent message that copies its text to the clipboard."), systemImage: "doc.on.doc")
                        }
                        if controls.canMutate {
                            Button {
                                controls.onEdit()
                            } label: {
                                Label(L10n.string("Edit", comment: "Context menu action on a sent message that loads its text back into the composer to edit and regenerate the reply."), systemImage: "pencil")
                            }
                        }
                    }
                } preview: {
                    MessageContextMenuPreview(
                        title: nil,
                        text: text,
                        attachments: attachments
                    )
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Chat.Message.user)
    }

    private func userSkillBubble(
        _ invocation: UserSkillInvocation,
        attachments: [Artifact],
        createdAt: Date
    ) -> some View {
        HStack {
            Spacer(minLength: 40)
            UserSkillBubble(
                invocation: invocation,
                attachments: attachments,
                sourcePrefix: "block:\(block.id.uuidString)",
                onOpenAttachment: onOpenAttachment,
                onOpenSkill: onOpenSkill
            )
            .contextMenuPreviewShape()
            .contextMenu {
                Section(Self.timestampFormatter.string(from: createdAt)) {
                    Button {
                        controls.onCopy(invocation.argument.isEmpty ? "/\(invocation.skill.name)" : invocation.argument)
                    } label: {
                        Label(L10n.string("Copy", comment: "Context menu action on a sent message that copies its text to the clipboard."), systemImage: "doc.on.doc")
                    }
                }
            } preview: {
                MessageContextMenuPreview(
                    title: "/\(invocation.skill.displayName)",
                    text: invocation.argument,
                    attachments: attachments
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @ViewBuilder
    private func agentContentBubble(_ items: [ContentItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    switch item {
                    case let .text(text), let .progress(text):
                        if !text.isEmpty {
                            agentText(text)
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                                .padding(.horizontal, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .serviceControl:
                        EmptyView()
                    case let .serviceInspector(link):
                        ServiceInspectorRow(link: link, chatID: chatID)
                            .padding(.horizontal, 4)
                            .padding(.vertical, Theme.Spacing.xs)
                    case let .shoveler(shoveler):
                        ShovelerView(
                            shoveler: shoveler,
                            accessibilityPrefix: A11yID.Chat.Message.shoveler(block.id.uuidString),
                            onOpenArtifact: onOpenAttachment
                        )
                        .padding(.vertical, Theme.Spacing.xs)
                    case let .video(video):
                        VideoWidgetView(video: video)
                            .padding(.horizontal, 4)
                            .padding(.vertical, Theme.Spacing.xs)
                    case let .artifact(artifact):
                        if artifact.exists {
                            let sourceID = "block:\(block.id.uuidString):\(index):\(artifact.id)"
                            Button { onOpenAttachment(artifact, sourceID) } label: {
                                ChatArtifactRow(artifact: artifact, previewSourceID: sourceID)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 4)
                            .padding(.vertical, Theme.Spacing.xs)
                            .accessibilityLabel(artifact.userFacingAccessibilityLabel)
                            .accessibilityIdentifier(A11yID.Chat.Message.artifact(artifact.id))
                            .contextMenuPreviewShape()
                            .contextMenu {
                                ArtifactContextMenu(artifact: artifact, canMutate: artifactControls.canMutate) {
                                    artifactControls.onRename(artifact)
                                } onDelete: {
                                    artifactControls.onDelete(artifact)
                                }
                            } preview: {
                                ArtifactContextMenuPreview(artifact: artifact)
                            }
                        } else {
                            ChatArtifactRow(artifact: artifact)
                                .padding(.horizontal, 4)
                                .padding(.vertical, Theme.Spacing.xs)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(String(
                                    format: L10n.string("Deleted artifact: %@"),
                                    artifact.userFacingName
                                ))
                                .accessibilityIdentifier(A11yID.Chat.Message.artifact(artifact.id))
                        }
                    case let .skill(skill):
                        Button { onOpenSkill(skill) } label: {
                            SkillLibraryRow(skill: skill)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .padding(.vertical, Theme.Spacing.xs)
                        .accessibilityLabel("/\(skill.displayName), \(skill.description)")
                        .accessibilityIdentifier(A11yID.Chat.Message.skill(skill.name))
                    }
                }
            }
            .animation(.easeOut(duration: Theme.Animation.standard), value: isStreamingTail)
            .onChange(of: isStreamingTail, initial: true) { _, streaming in
                if streaming { hasStreamed = true }
            }
        }
    }

    @ViewBuilder
    private func agentText(_ text: String) -> some View {
        if isStreamingTail || hasStreamed {
            StreamingMarkdownText(source: text)
                .environment(\.chatLinkHandler, onOpenLink)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.Chat.Message.agent)
        } else {
            MarkdownText(text)
                .environment(\.chatLinkHandler, onOpenLink)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(text)
                .accessibilityIdentifier(A11yID.Chat.Message.agent)
        }
    }

}

struct ResponseFooterBlockView: View, Equatable {
    let id: UUID
    let text: String
    let isVisible: Bool
    let controls: MessageControls

    static func == (lhs: ResponseFooterBlockView, rhs: ResponseFooterBlockView) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.isVisible == rhs.isVisible
            && lhs.controls.isCopied == rhs.controls.isCopied
            && lhs.controls.isSpeaking == rhs.controls.isSpeaking
            && lhs.controls.canMutate == rhs.controls.canMutate
    }

    var body: some View {
        HStack(spacing: 1) {
            iconButton(
                systemName: controls.isCopied ? "checkmark" : "doc.on.doc",
                label: A11yLabel.copyMessage,
                id: A11yID.Chat.Message.copy,
                disabled: controls.isCopied
            ) {
                controls.onCopy(text)
            }
            ShareLink(item: text) {
                controlIcon(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(A11yLabel.shareMessage)
            .accessibilityIdentifier(A11yID.Chat.Message.share)
            if !text.isEmpty {
                iconButton(
                    systemName: controls.isSpeaking ? "stop.fill" : "speaker.wave.2",
                    label: controls.isSpeaking ? A11yLabel.stopReading : A11yLabel.readAloud,
                    id: A11yID.Chat.Message.readAloud
                ) {
                    controls.onReadAloud(text)
                }
            }
            if controls.canMutate {
                iconButton(
                    systemName: "arrow.branch",
                    label: A11yLabel.branchMessage,
                    id: A11yID.Chat.Message.branch
                ) {
                    controls.onBranch()
                }
                iconButton(
                    systemName: "arrow.clockwise",
                    label: A11yLabel.retryMessage,
                    id: A11yID.Chat.Message.retry
                ) {
                    controls.onRetry()
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }

    private func iconButton(
        systemName: String,
        label: String,
        id: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            controlIcon(systemName: systemName)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func controlIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.Colors.onSurfaceMuted)
            .frame(width: 18, height: 28)
            .frame(width: 28, height: Theme.Size.minimumTouchTarget, alignment: .leading)
            .contentShape(Rectangle())
    }
}
