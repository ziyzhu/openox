import SwiftUI
import UIKit
import Observation

struct StreamingMarkdownText: View {
    let source: String
    let accessibilityIdentifier: String
    var isStreaming = true
    @State private var availableWidth: CGFloat = 0
    @State private var buffer = Buffer()

    var body: some View {
        let snapshot = buffer.snapshot
        let hasInteractiveCode = snapshot.blocks.contains { block in
            if case .code(let language, _) = block {
                return DiffDocument.supports(language) || language == "map" || language == "mermaid"
            }
            if case .embed = block { return true }
            return false
        }
        let blocks = MarkdownRenderBlock.group(snapshot.blocks)
        let receivingIndex = snapshot.receivingBlockIndex(in: blocks)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownRenderBlockView(
                    block: block,
                    textColor: Theme.Colors.onSurface,
                    subtleColor: Theme.Colors.onSurfaceMuted,
                    availableWidth: availableWidth,
                    accessibilityIdentifier: "\(accessibilityIdentifier).block.\(index)",
                    fadeKey: snapshot.fadeKey,
                    isStreaming: snapshot.input.isStreaming,
                    isReceiving: index == receivingIndex,
                    streamingProse: buffer.prose(at: index)
                )
                .id(snapshot.generation)
                .padding(.top, MarkdownText.spacing(
                    before: block.first,
                    after: index == 0 ? nil : blocks[index - 1].last
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: hasInteractiveCode ? .contain : .ignore)
        .accessibilityLabel(source, isEnabled: !hasInteractiveCode)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: Input(source: source, isStreaming: isStreaming), initial: true) { _, input in
            buffer.update(input)
        }
        .onDisappear { buffer.cancel() }
    }

    nonisolated fileprivate struct Input: Equatable, Sendable {
        let source: String
        let isStreaming: Bool
    }

    nonisolated fileprivate struct Settled: Sendable {
        var utf8Count = 0
        var blocks: [MarkdownBlock] = []
    }

    @MainActor
    @Observable
    fileprivate final class Buffer {
        struct Snapshot {
            let input: Input
            let blocks: [MarkdownBlock]
            let generation: Int
            let fadeKey: Int?
            var inFence = false

            func receivingBlockIndex(in blocks: [MarkdownRenderBlock]) -> Int? {
                guard input.isStreaming, let last = blocks.last else { return nil }
                if case .block(.code) = last, !inFence { return nil }
                return blocks.count - 1
            }
        }

        private(set) var snapshot = Snapshot(
            input: Input(source: "", isStreaming: false), blocks: [], generation: 0, fadeKey: nil
        )
        @ObservationIgnored private var latest: Input?
        @ObservationIgnored private var pending: (input: Input, generation: Int, fadeKey: Int?)?
        @ObservationIgnored private var generation = 0
        @ObservationIgnored private var fadeKey: Int?
        @ObservationIgnored private var settled = Settled()
        @ObservationIgnored private var prose: [SelectableText.StreamingProse] = []
        @ObservationIgnored private var scheduled: Task<Void, Never>?
        @ObservationIgnored private var parsedAt: ContinuousClock.Instant?

        func update(_ input: Input) {
            guard latest != input else { return }
            let previous = latest?.source ?? snapshot.input.source
            if !input.source.utf8.starts(with: previous.utf8) {
                generation &+= 1
                fadeKey = nil
                settled = Settled()
                prose.removeAll()
            }
            if input.isStreaming { fadeKey = generation }
            latest = input
            if snapshot.blocks.isEmpty, scheduled == nil, !input.isStreaming {
                snapshot = Snapshot(input: input, blocks: MarkdownParser.shared.blocks(input.source),
                                    generation: generation, fadeKey: fadeKey)
                return
            }
            pending = (input, generation, fadeKey)
            scheduleIfNeeded()
        }

        private func scheduleIfNeeded() {
            guard scheduled == nil, let pending else { return }
            let interval = snapshot.blocks.isEmpty || !pending.input.isStreaming ? 0
                : pending.input.source.utf8.count > 2_048 ? 0.1 : 1.0 / 30.0
            let wait = parsedAt.map { max(.zero, .seconds(interval) - $0.duration(to: .now)) } ?? .zero
            scheduled = Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled, let request = self.pending else { return }
                self.pending = nil
                parsedAt = .now
                let parsed = try? await MarkdownParser.shared.snapshot(
                    source: request.input.source, isStreaming: request.input.isStreaming, settled: settled
                )
                guard !Task.isCancelled else { return }
                scheduled = nil
                if let parsed, request.generation == generation {
                    settled = parsed.settled
                    if !request.input.isStreaming, snapshot.input.isStreaming {
                        Log.ui.debug("StreamingMarkdown.settled generation=\(generation) bytes=\(request.input.source.utf8.count) blocks=\(parsed.blocks.count)")
                    }
                    snapshot = Snapshot(input: request.input, blocks: parsed.blocks,
                                        generation: request.generation, fadeKey: request.fadeKey,
                                        inFence: parsed.inFence)
                }
                scheduleIfNeeded()
            }
        }

        func prose(at index: Int) -> SelectableText.StreamingProse {
            while prose.count <= index { prose.append(SelectableText.StreamingProse()) }
            return prose[index]
        }

        func cancel() {
            scheduled?.cancel()
            scheduled = nil
            pending = nil
            latest = nil
        }

        deinit { scheduled?.cancel() }
    }

    nonisolated static func split(_ source: String) -> (settled: String, tail: String, inFence: Bool) {
        let lines = source.components(separatedBy: "\n")
        var inFence = false
        var boundary = 0
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            } else if !inFence && line.isEmpty && i < lines.count - 1 {
                boundary = i + 1
            }
        }
        return (lines[0..<boundary].joined(separator: "\n"),
                lines[boundary...].joined(separator: "\n"), inFence)
    }

    static func balanced(_ source: String) -> String {
        var trimmed = Substring(source)
        while let last = trimmed.last, last == "*" || last == "`" {
            trimmed = trimmed.dropLast()
        }
        var out = String(trimmed)
        let backticks = out.count(where: { $0 == "`" })
        if backticks % 2 == 1 { out += "`" }
        let stars = out.count(where: { $0 == "*" })
        let doubles = out.components(separatedBy: "**").count - 1
        if doubles % 2 == 1 { out += "**" }
        if (stars - doubles * 2) % 2 == 1 { out += "*" }
        return out
    }

    nonisolated static func stableWords(_ source: String) -> String {
        guard let last = source.last, !last.isWhitespace,
              !canBreakBefore(last) else { return source }
        let pending = source.reversed().prefix { character in
            !character.isWhitespace && !canBreakBefore(character)
        }
        return String(source.dropLast(pending.count))
    }

    nonisolated private static func canBreakBefore(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isIdeographic || scalar.properties.isEmojiPresentation
                || (0x3000...0xD7FF).contains(scalar.value)
        }
    }

    nonisolated static func gateInlineLinks(_ source: String) -> String {
        enum State {
            case text
            case label(start: String.Index, depth: Int)
            case destinationPending(start: String.Index, labelEnd: String.Index)
            case destination(start: String.Index, labelEnd: String.Index, depth: Int)
        }

        var state = State.text
        var escaped = false
        var codeTicks: Int?
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]

            if let activeTicks = codeTicks {
                if character == "`" {
                    var end = source.index(after: index)
                    while end < source.endIndex, source[end] == "`" {
                        end = source.index(after: end)
                    }
                    if source.distance(from: index, to: end) == activeTicks { codeTicks = nil }
                    index = end
                } else {
                    index = source.index(after: index)
                }
                continue
            }

            if escaped {
                escaped = false
                index = source.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = source.index(after: index)
                continue
            }

            if character == "`" {
                var end = source.index(after: index)
                while end < source.endIndex, source[end] == "`" {
                    end = source.index(after: end)
                }
                let count = source.distance(from: index, to: end)
                if case .text = state {
                    codeTicks = count
                } else if case .label = state {
                    codeTicks = count
                }
                index = end
                continue
            }

            switch state {
            case .text:
                if character == "[" { state = .label(start: index, depth: 1) }
            case .label(let start, let depth):
                if character == "[" {
                    state = .label(start: start, depth: depth + 1)
                } else if character == "]" {
                    state = depth == 1
                        ? .destinationPending(start: start, labelEnd: index)
                        : .label(start: start, depth: depth - 1)
                }
            case .destinationPending(let start, let labelEnd):
                if character == "(" {
                    state = .destination(start: start, labelEnd: labelEnd, depth: 1)
                } else {
                    state = .text
                    continue
                }
            case .destination(let start, let labelEnd, let depth):
                if character == "(" {
                    state = .destination(start: start, labelEnd: labelEnd, depth: depth + 1)
                } else if character == ")" {
                    state = depth == 1
                        ? .text
                        : .destination(start: start, labelEnd: labelEnd, depth: depth - 1)
                }
            }
            index = source.index(after: index)
        }

        switch state {
        case .text:
            return source
        case .label(let start, _):
            return String(source[..<start] + source[source.index(after: start)...])
        case .destinationPending(let start, let labelEnd), .destination(let start, let labelEnd, _):
            return String(source[..<start] + source[source.index(after: start)..<labelEnd])
        }
    }
}

nonisolated private enum StreamingMarkdownTail {
    nonisolated static func gate(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if isAmbiguousLineStart(trimmed) || (trimmed.hasPrefix("![") && !trimmed.hasSuffix(")")) {
                lines.removeLast()
            } else if trimmed.hasPrefix("|"), !endsInConfirmedTable(lines) {
                lines.removeLast()
            } else {
                break
            }
        }
        return StreamingMarkdownText.gateInlineLinks(lines.joined(separator: "\n"))
    }

    nonisolated private static func endsInConfirmedTable(_ lines: [String]) -> Bool {
        var start = lines.count - 1
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            start -= 1
        }
        guard start + 1 < lines.count else { return false }
        return MarkdownBlock.isTableSeparator(lines[start + 1].trimmingCharacters(in: .whitespaces))
    }

    nonisolated static func isAmbiguousLineStart(_ line: String) -> Bool {
        if line.isEmpty { return true }
        guard line.count <= 7 else { return false }
        if line.allSatisfy({ $0 == "#" }) && line.count <= 6 { return true }
        if line == "*" || line == "+" || line == ">" { return true }
        if line.allSatisfy({ $0 == "-" }) && line.count <= 3 { return true }
        if line == "`" || line == "``" { return true }
        if line.allSatisfy(\.isNumber) { return true }
        if line.last == ".", !line.dropLast().isEmpty, line.dropLast().allSatisfy(\.isNumber) { return true }
        if line == "**" || line == "***" { return true }
        return false
    }
}

struct MarkdownText: View {
    static func spacing(before block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat {
        guard let previous else { return 0 }
        return switch (previous, block) {
        case (.paragraph, .lists): 8
        case (.heading, .paragraph): 16
        default: ConversationTranscriptMetrics.blockSpacing
        }
    }

    static func headingInset(_ block: MarkdownBlock) -> CGFloat {
        guard case .heading(let level, _) = block else { return 0 }
        return level <= 2 ? 4 : 2
    }

    let source: String
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let accessibilityIdentifier: String
    static let bodyFont = UIFont.preferredFont(forTextStyle: .body)
    @State private var availableWidth: CGFloat = 0
    @State private var blocks: [MarkdownRenderBlock] = []

    init(
        _ source: String,
        accessibilityIdentifier: String,
        textColor: DynamicColor = Theme.Colors.onSurface,
        subtleColor: DynamicColor = Theme.Colors.onSurfaceMuted
    ) {
        self.source = source
        self.accessibilityIdentifier = accessibilityIdentifier
        self.textColor = textColor
        self.subtleColor = subtleColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownRenderBlockView(block: block, textColor: textColor,
                                        subtleColor: subtleColor, availableWidth: availableWidth,
                                        accessibilityIdentifier: "\(accessibilityIdentifier).block.\(index)")
                    .padding(
                        .top,
                        MarkdownText.spacing(
                            before: block.first,
                            after: index == 0 ? nil : blocks[index - 1].last
                        )
                    )
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: source) {
            guard let rendered = try? await MarkdownParser.shared.render(source), !Task.isCancelled else { return }
            blocks = rendered
        }
    }
}

nonisolated private enum MarkdownRenderBlock: Equatable, Sendable {
    case prose([MarkdownBlock])
    case block(MarkdownBlock)
    case embeds([MarkdownBlock])

    var first: MarkdownBlock {
        switch self {
        case .prose(let blocks), .embeds(let blocks): blocks.first ?? .paragraph("")
        case .block(let block): block
        }
    }

    var last: MarkdownBlock {
        switch self {
        case .prose(let blocks), .embeds(let blocks): blocks.last ?? .paragraph("")
        case .block(let block): block
        }
    }

    private static let proseByteLimit = 3_000

    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownRenderBlock] {
        var grouped: [MarkdownRenderBlock] = []
        var prose: [MarkdownBlock] = []
        var proseBytes = 0
        func closeProse() {
            guard !prose.isEmpty else { return }
            grouped.append(.prose(prose))
            prose = []
            proseBytes = 0
        }
        for block in blocks {
            switch block {
            case .paragraph, .heading, .lists:
                let followsHeading = if case .heading = prose.last { true } else { false }
                if proseBytes >= proseByteLimit, !followsHeading { closeProse() }
                prose.append(block)
                proseBytes += byteCount(block)
            case .embed:
                closeProse()
                switch grouped.last {
                case .embeds(let embeds):
                    grouped[grouped.count - 1] = .embeds(embeds + [block])
                case .block(.embed(let alt, let path)):
                    grouped[grouped.count - 1] = .embeds([.embed(alt: alt, path: path), block])
                default:
                    grouped.append(.block(block))
                }
            case .code, .quote, .table, .rule:
                closeProse()
                grouped.append(.block(block))
            }
        }
        closeProse()
        return grouped
    }

    private static func byteCount(_ block: MarkdownBlock) -> Int {
        switch block {
        case .paragraph(let text), .heading(_, let text): text.utf8.count
        case .lists(let lists): lists.utf8Count
        case .code, .quote, .table, .rule, .embed: 0
        }
    }
}

private struct MarkdownRenderBlockView: View {
    @Environment(\.colorScheme) private var colorScheme
    let block: MarkdownRenderBlock
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let availableWidth: CGFloat
    let accessibilityIdentifier: String
    var fadeKey: Int? = nil
    var isStreaming = false
    var isReceiving = false
    var streamingProse: SelectableText.StreamingProse? = nil

    var body: some View {
        switch block {
        case .prose(let blocks):
            prose(attributedProse(blocks))
                .padding(.top, SelectableText.proseTopInset(block.first))
        case .embeds(let blocks):
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        if case let .embed(alt, path) = block {
                            MarkdownEmbedView(alt: alt, path: path)
                                .frame(width: 240)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .defaultScrollAnchor(.leading)
            .excludesCompactPageSwitch()
            .accessibilityIdentifier("\(accessibilityIdentifier).embeds")
        case .block(let block):
            MarkdownBlockView(
                block: block,
                textColor: textColor,
                subtleColor: subtleColor,
                availableWidth: availableWidth,
                accessibilityIdentifier: accessibilityIdentifier,
                fadeKey: fadeKey,
                isStreaming: isStreaming && isReceiving
            )
        }
    }

    private func attributedProse(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let color = UIColor(hex: textColor.hex(for: colorScheme))
        if isStreaming, let streamingProse {
            return streamingProse.render(blocks, color: color)
        }
        return SelectableText.attributedMarkdownProse(blocks, color: color)
    }

    @ViewBuilder
    private func prose(_ attributed: NSAttributedString) -> some View {
        if let fadeKey {
            StreamingFadeSelectableText(attributed: attributed, resetKey: fadeKey)
        } else {
            SelectableText(attributed)
        }
    }
}

private struct MarkdownBlockView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.conversationLinkHandler) private var conversationLinkHandler
    let block: MarkdownBlock
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let availableWidth: CGFloat
    let accessibilityIdentifier: String
    var fadeKey: Int? = nil
    var isStreaming = false

    private static let tableCellMinWidth: CGFloat = 88
    private static let tableCellMaxWidth: CGFloat = 220

    var body: some View {
        switch block {
        case .paragraph, .heading, .lists:
            SelectableText(SelectableText.attributedMarkdownProse([block], color: UIColor(hex: textColor.hex(for: colorScheme))))
                .padding(.top, SelectableText.proseTopInset(block))
        case .code(let language, let body):
            if language == "mermaid", !isStreaming {
                MermaidDiagramView(source: body, maxWidth: availableWidth, accessibilityIdentifier: accessibilityIdentifier) {
                    codeBlock(body, language: language)
                }
            } else if language == "map", !isStreaming {
                ConversationMapView(source: body, accessibilityIdentifier: accessibilityIdentifier) {
                    codeBlock(body, language: language)
                }
                .environment(\.openURL, openURL)
            } else {
                codeBlock(body, language: language)
            }
        case .quote(let text):
            quote(text)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Colors.onSurfaceMuted)
                        .frame(width: 3)
                }
        case let .table(header, rows):
            let columns = max(header.count, rows.map(\.count).max() ?? 1)
            let cellWidth = Self.tableCellWidth(forColumns: columns, in: availableWidth)
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, col in
                            tableCell(col, width: cellWidth, header: true)
                        }
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        Divider()
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                tableCell(cell, width: cellWidth)
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .excludesCompactPageSwitch()
            .defaultScrollAnchor(nil, for: .sizeChanges)
            .environment(\.openURL, openURL)
        case .rule:
            Divider()
        case let .embed(alt, path):
            MarkdownEmbedView(alt: alt, path: path)
        }
    }

    private var openURL: OpenURLAction {
        OpenURLAction { [conversationLinkHandler, serviceManager] url in
            if let conversationLinkHandler { conversationLinkHandler(url) }
            else { LinkOpener.open(url: url, serviceManager: serviceManager) }
            return .handled
        }
    }

    @ViewBuilder
    private func quote(_ text: String) -> some View {
        if let fadeKey {
            StreamingFadeSelectableText(markdown: isStreaming ? StreamingMarkdownText.balanced(text) : text, resetKey: fadeKey,
                                        font: MarkdownText.bodyFont, color: subtleColor.uiColor, lineSpacing: 2)
        } else {
            SelectableText(markdown: text, font: MarkdownText.bodyFont, color: subtleColor.uiColor, lineSpacing: 2)
        }
    }

    private func codeBlock(_ body: String, language: String?) -> some View {
        CodeBlockSurface(scrollsHorizontally: !DiffDocument.supports(language)) {
            CodeBlockHeader(language: language, code: body, isStreaming: isStreaming) {
                CodeBlockCopyButton(code: body, accessibilityIdentifier: "\(accessibilityIdentifier).copy")
            }
        } content: {
            codeBody(body, language: language)
        }
    }

    @ViewBuilder
    private func codeBody(_ body: String, language: String?) -> some View {
        if DiffDocument.supports(language) {
            DiffCodeBlockBody(code: body, accessibilityIdentifier: accessibilityIdentifier,
                              fadeKey: fadeKey, isStreaming: isStreaming)
        } else if let fadeKey {
            StreamingFadeSelectableText(code: body, language: language, resetKey: fadeKey)
        } else {
            SelectableText(code: body, language: language)
        }
    }

    private func tableCell(_ text: String, width: CGFloat, header: Bool = false) -> some View {
        inline(text)
            .font(header ? Theme.Fonts.bodySm.weight(.semibold) : Theme.Fonts.bodySm)
            .foregroundStyle(textColor)
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func tableCellWidth(forColumns columns: Int, in available: CGFloat) -> CGFloat {
        guard available > 0, columns > 0 else { return tableCellMaxWidth }
        let fit = (available - Theme.Spacing.md * CGFloat(columns - 1)) / CGFloat(columns)
        return min(tableCellMaxWidth, max(tableCellMinWidth, fit))
    }

    private func inline(_ source: String) -> Text {
        if var attributed = SelectableText.inlineMarkdown(source) {
            let links = attributed.runs.compactMap { $0.link == nil ? nil : $0.range }
            let code = attributed.runs.compactMap {
                $0.inlinePresentationIntent?.contains(.code) == true ? $0.range : nil
            }
            attributed.removeInlinePresentationIntent(.emphasized)
            for range in links {
                attributed[range].foregroundColor = textColor.dynamic
                attributed[range].underlineStyle = Text.LineStyle(pattern: .dot)
            }
            for range in code {
                attributed[range].foregroundColor = Theme.Colors.conversationInlineCode.dynamic
                if let intent = attributed[range].inlinePresentationIntent {
                    let remaining = intent.subtracting(.code)
                    attributed[range].inlinePresentationIntent = remaining.isEmpty ? nil : remaining
                }
            }
            return Text(attributed)
        }
        return Text(source)
    }
}

extension AttributedString {
    mutating func removeInlinePresentationIntent(_ removed: InlinePresentationIntent) {
        let intents = runs.compactMap { run in
            run.inlinePresentationIntent.map { (run.range, $0) }
        }
        for (range, intent) in intents where intent.contains(removed) {
            let remaining = intent.subtracting(removed)
            self[range].inlinePresentationIntent = remaining.isEmpty ? nil : remaining
        }
    }
}

private struct CodeBlockCopyButton: View {
    let code: String
    let accessibilityIdentifier: String
    @State private var feedback = CopyFeedback()

    var body: some View {
        Button {
            feedback.copy(code, logMessage: "MarkdownText.copyCodeBlock chars=\(code.count)")
        } label: {
            Image(systemName: feedback.didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurface)
                .frame(width: 22, height: 22, alignment: .trailing)
                .minimumTouchTarget(alignment: .topTrailing)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22, alignment: .topTrailing)
        .disabled(feedback.didCopy)
        .accessibilityLabel(A11yLabel.copyCode)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private actor MarkdownParser {
    static let shared = MarkdownParser()

    nonisolated private final class Cached: Sendable {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    nonisolated(unsafe) private let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 256
        cache.totalCostLimit = TextRenderCachePolicy.parsedLimit
        return cache
    }()

    func parse(_ source: String) throws -> [MarkdownBlock] {
        try Task.checkCancellation()
        return blocks(source)
    }

    nonisolated func blocks(_ source: String) -> [MarkdownBlock] {
        let key = TextRenderCachePolicy.key(source)
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = MarkdownBlock.parse(source)
        let cost = TextRenderCachePolicy.parsedCost(sourceByteCount: source.utf8.count, blockCount: blocks.count)
        if cost <= cache.totalCostLimit {
            cache.setObject(Cached(blocks), forKey: key, cost: cost)
        }
        return blocks
    }

    func snapshot(
        source: String,
        isStreaming: Bool,
        settled: StreamingMarkdownText.Settled
    ) throws -> (blocks: [MarkdownBlock], settled: StreamingMarkdownText.Settled, inFence: Bool) {
        guard isStreaming else { return (try parse(source), settled, false) }
        try Task.checkCancellation()
        var settled = settled
        let open = String(decoding: source.utf8.dropFirst(settled.utf8Count), as: UTF8.self)
        let split = StreamingMarkdownText.split(open)
        let consumed = open.utf8.count - split.tail.utf8.count
        if consumed > 0 {
            settled.blocks += MarkdownBlock.parse(split.settled)
            settled.utf8Count += consumed
        }
        let tail = split.inFence ? split.tail : StreamingMarkdownText.stableWords(split.tail)
        return (settled.blocks + MarkdownBlock.parse(StreamingMarkdownTail.gate(tail)), settled, split.inFence)
    }

    func render(_ source: String) throws -> [MarkdownRenderBlock] {
        MarkdownRenderBlock.group(try parse(source))
    }
}
