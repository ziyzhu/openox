import SwiftUI
import UIKit
import Observation

struct StreamingMarkdownText: View {
    let source: String
    let accessibilityIdentifier: String
    var isStreaming = true
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.conversationLinkHandler) private var conversationLinkHandler
    @State private var availableWidth: CGFloat = 0
    @State private var buffer = Buffer()

    var body: some View {
        let snapshot = buffer.snapshot
        let hasInteractiveCode = snapshot.blocks.contains { block in
            if case .code(let language, _) = block { return DiffDocument.supports(language) }
            if case .embed = block { return true }
            return false
        }
        let blocks = MarkdownRenderBlock.group(snapshot.blocks)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownRenderBlockView(
                    block: block,
                    textColor: Theme.Colors.onSurface,
                    subtleColor: Theme.Colors.conversationSecondary,
                    availableWidth: availableWidth,
                    accessibilityIdentifier: "\(accessibilityIdentifier).block.\(index)",
                    fadeKey: snapshot.fadeKey,
                    isStreaming: snapshot.input.isStreaming,
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
        .accessibilityElement(children: hasInteractiveCode ? .contain : .combine)
        .accessibilityLabel(source, isEnabled: !isStreaming && !hasInteractiveCode)
        .environment(\.openURL, OpenURLAction { url in
            if let conversationLinkHandler { conversationLinkHandler(url) }
            else { LinkOpener.open(url: url, serviceManager: serviceManager) }
            return .handled
        })
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

        func update(_ input: Input) {
            guard latest != input else { return }
            let previous = latest?.source ?? snapshot.input.source
            if !input.source.hasPrefix(previous) {
                generation &+= 1
                fadeKey = nil
                settled = Settled()
                prose.removeAll()
            }
            if input.isStreaming { fadeKey = generation }
            latest = input
            if snapshot.blocks.isEmpty, scheduled == nil, !input.isStreaming,
               let blocks = MarkdownParser.shared.cached(input.source) {
                snapshot = Snapshot(input: input, blocks: blocks, generation: generation, fadeKey: fadeKey)
                return
            }
            pending = (input, generation, fadeKey)
            scheduleIfNeeded()
        }

        private func scheduleIfNeeded() {
            guard scheduled == nil, let pending else { return }
            let interval = snapshot.blocks.isEmpty || !pending.input.isStreaming ? 0
                : pending.input.source.utf8.count > 2_048 ? 0.1 : 1.0 / 30.0
            scheduled = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, let request = self.pending else { return }
                self.pending = nil
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
                                        generation: request.generation, fadeKey: request.fadeKey)
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
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.conversationLinkHandler) private var conversationLinkHandler
    static let bodyFont = UIFont.preferredFont(forTextStyle: .body)
    @State private var availableWidth: CGFloat = 0
    @State private var blocks: [MarkdownRenderBlock] = []

    init(
        _ source: String,
        accessibilityIdentifier: String,
        textColor: DynamicColor = Theme.Colors.onSurface,
        subtleColor: DynamicColor = Theme.Colors.conversationSecondary
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
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .task(id: source) {
            guard let rendered = try? await MarkdownParser.shared.render(source), !Task.isCancelled else { return }
            blocks = rendered
        }
    }

    private func open(_ url: URL) {
        if let conversationLinkHandler {
            conversationLinkHandler(url)
        } else {
            LinkOpener.open(url: url, serviceManager: serviceManager)
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

    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownRenderBlock] {
        var grouped: [MarkdownRenderBlock] = []
        for block in blocks {
            switch block {
            case .paragraph, .heading, .lists:
                if case .prose(let prose) = grouped.last {
                    grouped[grouped.count - 1] = .prose(prose + [block])
                } else {
                    grouped.append(.prose([block]))
                }
            case .embed:
                switch grouped.last {
                case .embeds(let embeds):
                    grouped[grouped.count - 1] = .embeds(embeds + [block])
                case .block(.embed(let alt, let path)):
                    grouped[grouped.count - 1] = .embeds([.embed(alt: alt, path: path), block])
                default:
                    grouped.append(.block(block))
                }
            case .code, .quote, .table, .rule:
                grouped.append(.block(block))
            }
        }
        return grouped
    }
}

private struct MarkdownRenderBlockView: View {
    let block: MarkdownRenderBlock
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let availableWidth: CGFloat
    let accessibilityIdentifier: String
    var fadeKey: Int? = nil
    var isStreaming = false
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
                isStreaming: isStreaming
            )
        }
    }

    private func attributedProse(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        if isStreaming, let streamingProse {
            return streamingProse.render(blocks, color: textColor.uiColor)
        }
        return SelectableText.attributedMarkdownProse(blocks, color: textColor.uiColor)
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
            SelectableText(SelectableText.attributedMarkdownProse([block], color: textColor.uiColor))
                .padding(.top, SelectableText.proseTopInset(block))
        case .code(let language, let body):
            if language == "mermaid", !isStreaming {
                MermaidDiagramView(source: body, maxWidth: availableWidth, accessibilityIdentifier: accessibilityIdentifier) {
                    codeBlock(body, language: language)
                }
            } else {
                codeBlock(body, language: language)
            }
        case .quote(let text):
            quote(text)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Colors.conversationSecondary)
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
        case .rule:
            Divider()
        case let .embed(alt, path):
            MarkdownEmbedView(alt: alt, path: path)
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
                .frame(width: 22, height: 22)
                .minimumTouchTarget(alignment: .topTrailing)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22, alignment: .topTrailing)
        .disabled(feedback.didCopy)
        .accessibilityLabel(A11yLabel.copyCode)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

nonisolated enum MarkdownListKind: Equatable, Sendable {
    case bullets
    case ordered
}

nonisolated struct MarkdownListItem: Equatable, Sendable {
    let text: String
    let children: [MarkdownList]
}

nonisolated struct MarkdownList: Equatable, Sendable {
    let kind: MarkdownListKind
    let items: [MarkdownListItem]
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

    nonisolated func cached(_ source: String) -> [MarkdownBlock]? {
        cache.object(forKey: TextRenderCachePolicy.key(source))?.blocks
    }

    func parse(_ source: String) throws -> [MarkdownBlock] {
        try Task.checkCancellation()
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
    ) throws -> (blocks: [MarkdownBlock], settled: StreamingMarkdownText.Settled) {
        guard isStreaming else { return (try parse(source), settled) }
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
        return (settled.blocks + MarkdownBlock.parse(StreamingMarkdownTail.gate(tail)), settled)
    }

    func render(_ source: String) throws -> [MarkdownRenderBlock] {
        MarkdownRenderBlock.group(try parse(source))
    }
}

nonisolated enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(Int, String)
    case lists([MarkdownList])
    case code(language: String?, body: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
    case embed(alt: String, path: String)

    var logShape: String {
        switch self {
        case .paragraph(let text): return "paragraph(chars:\(text.count))"
        case .heading(let level, let text): return "heading(level:\(level),chars:\(text.count))"
        case .lists(let lists): return "lists(groups:\(lists.count),items:\(lists.itemCount),chars:\(lists.characterCount))"
        case .code(let language, let body): return "code(language:\(language ?? "none"),chars:\(body.count))"
        case .quote(let text): return "quote(chars:\(text.count))"
        case .table(let header, let rows): return "table(columns:\(header.count),rows:\(rows.count))"
        case .rule: return "rule"
        case .embed: return "embed"
        }
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { i += 1; continue }

            if trimmed.hasPrefix("```") {
                let languageHint = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let language = languageHint.isEmpty ? nil : languageHint
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                out.append(.code(language: language, body: body.joined(separator: "\n")))
                continue
            }

            if let embed = embed(trimmed) {
                out.append(embed); i += 1; continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                out.append(.rule); i += 1; continue
            }

            if trimmed.hasPrefix("#") {
                var level = 0
                for ch in trimmed { if ch == "#" { level += 1 } else { break } }
                if level <= 6, trimmed.count > level, trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    out.append(.heading(level, String(trimmed.dropFirst(level + 1))))
                    i += 1; continue
                }
            }

            if trimmed.hasPrefix("> ") {
                var quoted: [String] = [String(trimmed.dropFirst(2))]
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("> ") {
                    quoted.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                out.append(.quote(quoted.joined(separator: " ")))
                continue
            }

            if listLine(line) != nil {
                var listLines: [MarkdownListLine] = []
                while i < lines.count, let listLine = listLine(lines[i]) {
                    listLines.append(listLine)
                    i += 1
                }
                var listIndex = 0
                out.append(.lists(parseLists(
                    listLines,
                    index: &listIndex,
                    indentation: listLines[0].indentation
                )))
                continue
            }

            if isTableStart(at: i, in: lines) {
                let header = splitRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || !t.contains("|") { break }
                    rows.append(normalizeRow(splitRow(t), width: header.count))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }

            var para: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("```") || t.hasPrefix("> ")
                    || isBullet(t) || isOrdered(t) || t == "---" || isTableStart(at: i, in: lines) { break }
                para.append(t); i += 1
            }
            out.append(.paragraph(para.joined(separator: " ")))
        }
        return out
    }

    static func embed(_ line: String) -> MarkdownBlock? {
        guard let match = line.wholeMatch(of: /!\[([^\]]*)\]\(<?([^)>]+)>?\)/) else { return nil }
        let path = String(match.2).trimmingCharacters(in: .whitespaces)
        if path.contains(":") {
            guard let url = URLComponents(string: path), url.scheme == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else { return nil }
            return .embed(alt: String(match.1), path: path)
        }
        return .embed(alt: String(match.1), path: path.removingPercentEncoding ?? path)
    }

    private static func isTableStart(at i: Int, in lines: [String]) -> Bool {
        guard i + 1 < lines.count else { return false }
        let header = lines[i].trimmingCharacters(in: .whitespaces)
        let separator = lines[i + 1].trimmingCharacters(in: .whitespaces)
        return header.contains("|") && isTableSeparator(separator)
    }

    static func isTableSeparator(_ s: String) -> Bool {
        guard s.contains("|"), s.contains("-") else { return false }
        let cells = splitRow(s)
        return !cells.isEmpty && cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func normalizeRow(_ cells: [String], width: Int) -> [String] {
        if cells.count >= width { return Array(cells.prefix(width)) }
        return cells + Array(repeating: "", count: width - cells.count)
    }

    private static let emphasisWraps = ["**", "__", "*", "_"]

    private struct MarkdownListLine {
        let indentation: Int
        let kind: MarkdownListKind
        let body: String
    }

    private static func listLine(_ line: String) -> MarkdownListLine? {
        let indentation = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { width, character in
            width + (character == "\t" ? 4 : 1)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let body = bulletBody(trimmed) {
            return MarkdownListLine(indentation: indentation, kind: .bullets, body: body)
        }
        if let body = orderedBody(trimmed) {
            return MarkdownListLine(indentation: indentation, kind: .ordered, body: body)
        }
        return nil
    }

    private static func parseLists(
        _ lines: [MarkdownListLine],
        index: inout Int,
        indentation: Int
    ) -> [MarkdownList] {
        var lists: [MarkdownList] = []
        while index < lines.count, lines[index].indentation == indentation {
            let kind = lines[index].kind
            var items: [MarkdownListItem] = []
            while index < lines.count,
                  lines[index].indentation == indentation,
                  lines[index].kind == kind {
                let line = lines[index]
                index += 1
                var children: [MarkdownList] = []
                while index < lines.count, lines[index].indentation > indentation {
                    children += parseLists(lines, index: &index, indentation: lines[index].indentation)
                }
                items.append(MarkdownListItem(text: line.body, children: children))
            }
            lists.append(MarkdownList(kind: kind, items: items))
        }
        return lists
    }

    private static func isBullet(_ s: String) -> Bool { bulletBody(s) != nil }

    private static func bulletBody(_ s: String) -> String? {
        if let body = plainBulletBody(Substring(s)) { return body }
        for wrap in emphasisWraps {
            if let body = wrappedBulletBody(Substring(s), wrap: wrap) { return body }
        }
        return nil
    }

    private static func plainBulletBody(_ s: Substring) -> String? {
        var t = s
        guard let marker = t.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        t = t.dropFirst()
        guard t.first == " " else { return nil }
        return String(t.dropFirst())
    }

    private static func wrappedBulletBody(_ s: Substring, wrap: String) -> String? {
        var t = s
        guard t.hasPrefix(wrap) else { return nil }
        t = t.dropFirst(wrap.count)
        guard let marker = t.first, marker == "-" || marker == "*" || marker == "+" else { return nil }
        t = t.dropFirst()
        guard t.hasPrefix(wrap) else { return nil }
        t = t.dropFirst(wrap.count)
        guard t.first == " " else { return nil }
        return String(t.dropFirst())
    }

    private static func isOrdered(_ s: String) -> Bool { orderedBody(s) != nil }

    private static func orderedBody(_ s: String) -> String? {
        var t = Substring(s)
        let wrap = emphasisWraps.first { t.hasPrefix($0) } ?? ""
        t = t.dropFirst(wrap.count)
        let digits = t.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        t = t.dropFirst(digits.count)
        guard t.first == "." else { return nil }
        t = t.dropFirst()
        guard t.hasPrefix(wrap) else { return nil }
        t = t.dropFirst(wrap.count)
        guard t.first == " " else { return nil }
        return String(t.dropFirst())
    }
}

nonisolated private extension Array where Element == MarkdownList {
    var itemCount: Int {
        reduce(0) { count, list in
            count + list.items.reduce(0) { $0 + 1 + $1.children.itemCount }
        }
    }

    var characterCount: Int {
        reduce(0) { count, list in
            count + list.items.reduce(0) { $0 + $1.text.count + $1.children.characterCount }
        }
    }
}
