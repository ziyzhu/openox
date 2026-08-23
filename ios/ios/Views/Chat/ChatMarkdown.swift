import SwiftUI
import UIKit
import Observation

struct StreamingMarkdownText: View {
    let source: String
    @State private var splitter = StreamSplitter()

    var body: some View {
        let split = splitter.absorb(source)
        VStack(alignment: .leading, spacing: 0) {
            if !split.settled.isEmpty {
                MarkdownText(split.settled)
            }
            if !split.tail.isEmpty {
                StreamingMarkdownTail(
                    source: split.tail,
                    resetKey: split.generation,
                    previousBlock: split.lastSettledBlock
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The stream only ever appends, so the settled/tail boundary is advanced
    // incrementally: each absorb re-splits just the unsettled tail instead of
    // the whole accumulated message. Settled text always ends right after a
    // blank line outside a code fence, so every tail re-scan starts fence-free.
    final class StreamSplitter {
        private var settled = ""
        private var tail = ""
        private var consumedUTF8 = 0
        private var generation = 0
        private var lastSettledBlock: MarkdownBlock?
        private var scannedUTF8 = 0
        private var currentLine = ""
        private var inFence = false
        private var boundaryUTF8 = 0

        func absorb(_ source: String) -> (
            settled: String,
            tail: String,
            generation: Int,
            lastSettledBlock: MarkdownBlock?
        ) {
            let total = source.utf8.count
            if total < consumedUTF8 {
                (settled, tail, consumedUTF8) = ("", "", 0)
                generation &+= 1
                lastSettledBlock = nil
                resetScanner()
            }
            if total > consumedUTF8 {
                let delta = String(decoding: source.utf8.suffix(total - consumedUTF8), as: UTF8.self)
                tail += delta
                consumedUTF8 = total
                scan(delta)
                if boundaryUTF8 > 0 {
                    let settledLength = boundaryUTF8 - 1
                    let nextSettled = String(decoding: tail.utf8.prefix(settledLength), as: UTF8.self)
                    settled = settled.isEmpty ? nextSettled : settled + "\n" + nextSettled
                    tail = String(decoding: tail.utf8.suffix(tail.utf8.count - boundaryUTF8), as: UTF8.self)
                    generation &+= 1
                    lastSettledBlock = MarkdownBlock.parse(nextSettled).last ?? lastSettledBlock
                    resetScanner()
                    scan(tail)
                }
            }
            return (settled, tail, generation, lastSettledBlock)
        }

        private func scan(_ delta: String) {
            for character in delta {
                scannedUTF8 += String(character).utf8.count
                if character == "\n" {
                    let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("```") {
                        inFence.toggle()
                    } else if !inFence && currentLine.isEmpty {
                        boundaryUTF8 = scannedUTF8
                    }
                    currentLine = ""
                } else {
                    currentLine.append(character)
                }
            }
        }

        private func resetScanner() {
            scannedUTF8 = 0
            currentLine = ""
            inFence = false
            boundaryUTF8 = 0
        }
    }

    static func split(_ source: String) -> (settled: String, tail: String) {
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
                lines[boundary...].joined(separator: "\n"))
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

    static func gateInlineLinks(_ source: String) -> String {
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

private struct StreamingMarkdownTail: View {
    let source: String
    let resetKey: Int
    let previousBlock: MarkdownBlock?
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.chatLinkHandler) private var chatLinkHandler
    @State private var availableWidth: CGFloat = 0
    @State private var classifier = PlainParagraphClassifier()
    @State private var formattedBuffer = FormattedTailBuffer()
    #if DEBUG
    @State private var stability = StabilityProbe()
    #endif

    var body: some View {
        let plain = classifier.isPlain(source, reset: resetKey)
        let _ = formattedBuffer.revision
        let blocks = plain
            ? [MarkdownBlock.paragraph(source)]
            : formattedBuffer.blocks(for: source, reset: resetKey)
        #if DEBUG
        let _ = stability.check(blocks)
        #endif
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                MarkdownBlockView(block: block, textColor: Theme.Colors.onSurface,
                                  subtleColor: Theme.Colors.onSurfaceMuted,
                                  availableWidth: availableWidth,
                                  fadeKey: i == blocks.count - 1 ? resetKey : nil)
                    .padding(
                        .top,
                        MarkdownText.spacing(
                            before: block,
                            after: i == 0 ? previousBlock : blocks[i - 1]
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            open(url)
            return .handled
        })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
    }

    private func open(_ url: URL) {
        if let chatLinkHandler {
            chatLinkHandler(url)
        } else {
            LinkOpener.open(url: url, serviceManager: serviceManager)
        }
    }

    static func gate(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if isAmbiguousLineStart(trimmed) {
                lines.removeLast()
            } else if trimmed.hasPrefix("|"), !endsInConfirmedTable(lines) {
                lines.removeLast()
            } else {
                break
            }
        }
        return StreamingMarkdownText.gateInlineLinks(lines.joined(separator: "\n"))
    }

    private static func endsInConfirmedTable(_ lines: [String]) -> Bool {
        var start = lines.count - 1
        while start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            start -= 1
        }
        guard start + 1 < lines.count else { return false }
        return MarkdownBlock.isTableSeparator(lines[start + 1].trimmingCharacters(in: .whitespaces))
    }

    static func isAmbiguousLineStart(_ line: String) -> Bool {
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

    private final class PlainParagraphClassifier {
        private var consumedUTF8 = 0
        private var plain = true
        private var leadingResolved = false
        private var reset = Int.min

        func isPlain(_ source: String, reset nextReset: Int) -> Bool {
            let total = source.utf8.count
            if reset != nextReset || total < consumedUTF8 {
                reset = nextReset
                consumedUTF8 = 0
                plain = true
                leadingResolved = false
            }
            if !leadingResolved,
               let first = source.first(where: { !$0.isWhitespace }) {
                leadingResolved = true
                if "#>-+|".contains(first) || first.isNumber { plain = false }
            }
            guard plain, total > consumedUTF8 else { return plain }
            let delta = String(decoding: source.utf8.suffix(total - consumedUTF8), as: UTF8.self)
            consumedUTF8 = total
            plain = !delta.contains { "\r\n*_`[\\<>".contains($0) }
            return plain
        }
    }

    @MainActor
    @Observable
    final class FormattedTailBuffer {
        private(set) var revision = 0
        @ObservationIgnored private var reset = Int.min
        @ObservationIgnored private var current = ""
        @ObservationIgnored private var pending = ""
        @ObservationIgnored private var rendered: [MarkdownBlock] = []
        @ObservationIgnored private var scheduled: Task<Void, Never>?

        func blocks(for source: String, reset nextReset: Int) -> [MarkdownBlock] {
            if reset != nextReset {
                reset = nextReset
                current = source
                pending = source
                rendered = MarkdownBlock.parseTail(StreamingMarkdownTail.gate(source))
                scheduled?.cancel()
                scheduled = nil
                return rendered
            }
            pending = source
            scheduleIfNeeded(byteCount: source.utf8.count)
            return rendered
        }

        private func scheduleIfNeeded(byteCount: Int) {
            guard scheduled == nil, pending != current else { return }
            let interval = byteCount > 2_048 ? 0.1 : 1.0 / 30.0
            scheduled = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                current = pending
                rendered = MarkdownBlock.parseTail(StreamingMarkdownTail.gate(current))
                scheduled = nil
                revision &+= 1
            }
        }

        deinit {
            scheduled?.cancel()
        }
    }

    #if DEBUG
    private final class StabilityProbe {
        private var previous: [MarkdownBlock] = []

        func check(_ current: [MarkdownBlock]) {
            defer { previous = current }
            guard previous.count > 1, current.count >= previous.count, current.first == previous.first else { return }
            let settled = Array(previous.dropLast())
            let currentSettled = Array(current.prefix(settled.count))
            guard settled != currentSettled else { return }
            let changed = zip(settled, currentSettled).enumerated().first { $0.element.0 != $0.element.1 }
            Log.ui.error("StreamingMarkdownTail.reflow index=\(changed?.offset ?? -1) before=\(changed?.element.0.logShape ?? "unknown") after=\(changed?.element.1.logShape ?? "unknown") previous=\(settled.count) current=\(currentSettled.count)")
        }
    }
    #endif
}

struct MarkdownText: View {
    static let blockSpacing: CGFloat = 20
    static let responseFooterSpacing: CGFloat = 12

    static func spacing(before block: MarkdownBlock, after previous: MarkdownBlock?) -> CGFloat {
        guard let previous else { return 0 }
        return switch (previous, block) {
        case (.paragraph, .lists): 8
        case (.heading, .paragraph): 16
        default: blockSpacing
        }
    }

    let source: String
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.chatLinkHandler) private var chatLinkHandler
    static let bodyFont = UIFont.preferredFont(forTextStyle: .body)
    @State private var availableWidth: CGFloat = 0

    init(
        _ source: String,
        textColor: DynamicColor = Theme.Colors.onSurface,
        subtleColor: DynamicColor = Theme.Colors.onSurfaceMuted
    ) {
        self.source = source
        self.textColor = textColor
        self.subtleColor = subtleColor
    }

    var body: some View {
        let blocks = MarkdownRenderBlock.group(MarkdownBlock.parse(source))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownRenderBlockView(block: block, textColor: textColor,
                                        subtleColor: subtleColor, availableWidth: availableWidth)
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
    }

    private func open(_ url: URL) {
        if let chatLinkHandler {
            chatLinkHandler(url)
        } else {
            LinkOpener.open(url: url, serviceManager: serviceManager)
        }
    }
}

private enum MarkdownRenderBlock: Equatable {
    case paragraphs([String])
    case block(MarkdownBlock)

    var first: MarkdownBlock {
        switch self {
        case .paragraphs(let sources): .paragraph(sources.first ?? "")
        case .block(let block): block
        }
    }

    var last: MarkdownBlock {
        switch self {
        case .paragraphs(let sources): .paragraph(sources.last ?? "")
        case .block(let block): block
        }
    }

    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownRenderBlock] {
        var grouped: [MarkdownRenderBlock] = []
        for block in blocks {
            guard case .paragraph(let text) = block else {
                grouped.append(.block(block))
                continue
            }
            if case .paragraphs(let sources) = grouped.last {
                grouped[grouped.count - 1] = .paragraphs(sources + [text])
            } else {
                grouped.append(.paragraphs([text]))
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

    var body: some View {
        switch block {
        case .paragraphs(let sources):
            SelectableText(
                SelectableText.attributedMarkdownParagraphs(
                    sources,
                    font: MarkdownText.bodyFont,
                    color: textColor.uiColor,
                    lineSpacing: 1,
                    paragraphSpacing: MarkdownText.blockSpacing
                )
            )
        case .block(let block):
            MarkdownBlockView(
                block: block,
                textColor: textColor,
                subtleColor: subtleColor,
                availableWidth: availableWidth
            )
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let availableWidth: CGFloat
    var fadeKey: Int? = nil

    private static let tableCellMinWidth: CGFloat = 88
    private static let tableCellMaxWidth: CGFloat = 220

    var body: some View {
        switch block {
        case .paragraph(let text):
            prose(text, font: MarkdownText.bodyFont, color: textColor, lineSpacing: 1, fades: true)
        case .heading(let level, let text):
            prose(text, font: SelectableText.headingFont(level: level), color: textColor, lineSpacing: 2, fades: true)
                .padding(.top, level <= 2 ? 4 : 2)
        case .lists(let lists):
            MarkdownListsView(
                lists: lists,
                textColor: textColor,
                subtleColor: subtleColor,
                fadeKey: fadeKey
            )
        case .code(let language, let body):
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    if let language {
                        Text(language)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(subtleColor)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 22, alignment: .topLeading)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Theme.Colors.background.opacity(0.55),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: Theme.Radius.md,
                        topTrailingRadius: Theme.Radius.md,
                        style: .continuous
                    )
                )
                .overlay(alignment: .topTrailing) {
                    CodeBlockCopyButton(code: body)
                        .padding(Theme.Spacing.sm)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    codeBody(body, language: language)
                }
                .excludesCompactPageSwitch()
                .defaultScrollAnchor(nil, for: .sizeChanges)
            }
            .background(
                Theme.Colors.background,
                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            )
        case .quote(let text):
            prose(text, font: MarkdownText.bodyFont, color: subtleColor, lineSpacing: 2, fades: true)
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
        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func prose(_ text: String, font: UIFont, color: DynamicColor,
                       lineSpacing: CGFloat, fades: Bool) -> some View {
        if let fadeKey, fades {
            StreamingFadeSelectableText(markdown: StreamingMarkdownText.balanced(text), resetKey: fadeKey,
                                        font: font, color: color.uiColor, lineSpacing: lineSpacing)
        } else {
            SelectableText(markdown: text, font: font, color: color.uiColor, lineSpacing: lineSpacing)
        }
    }

    @ViewBuilder
    private func codeBody(_ body: String, language: String?) -> some View {
        if let fadeKey {
            StreamingFadeSelectableText(code: body, language: language, resetKey: fadeKey)
                .fixedSize(horizontal: true, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SelectableText(code: body, language: language)
                .fixedSize(horizontal: true, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                attributed[range].foregroundColor = Theme.Colors.onSurfaceMuted.dynamic
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

private struct MarkdownListsView: View {
    let lists: [MarkdownList]
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let fadeKey: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lists.enumerated()), id: \.offset) { index, list in
                MarkdownListView(
                    list: list,
                    textColor: textColor,
                    subtleColor: subtleColor,
                    fadeKey: index == lists.count - 1 ? fadeKey : nil
                )
            }
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let textColor: DynamicColor
    let subtleColor: DynamicColor
    let fadeKey: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(marker(for: index))
                            .font(.system(size: markerPointSize))
                            .monospacedDigit()
                            .foregroundStyle(textColor)
                            .frame(width: markerColumnWidth, alignment: .trailing)
                        prose(
                            item.text,
                            fades: index == list.items.count - 1 && item.children.isEmpty
                        )
                    }
                    if !item.children.isEmpty {
                        MarkdownListsView(
                            lists: item.children,
                            textColor: textColor,
                            subtleColor: subtleColor,
                            fadeKey: index == list.items.count - 1 ? fadeKey : nil
                        )
                        .padding(.leading, Theme.Spacing.lg)
                    }
                }
            }
        }
    }

    private var markerPointSize: CGFloat {
        switch list.kind {
        case .bullets: MarkdownText.bodyFont.pointSize * 1.35
        case .ordered: MarkdownText.bodyFont.pointSize
        }
    }

    private var markerColumnWidth: CGFloat {
        let lastMarker = marker(for: max(0, list.items.count - 1))
        let font = UIFont.monospacedDigitSystemFont(ofSize: markerPointSize, weight: .regular)
        return ceil((lastMarker as NSString).size(withAttributes: [.font: font]).width)
    }

    private func marker(for index: Int) -> String {
        switch list.kind {
        case .bullets: "•"
        case .ordered: "\(index + 1)."
        }
    }

    @ViewBuilder
    private func prose(_ text: String, fades: Bool) -> some View {
        if let fadeKey, fades {
            StreamingFadeSelectableText(
                markdown: StreamingMarkdownText.balanced(text),
                resetKey: fadeKey,
                font: MarkdownText.bodyFont,
                color: textColor.uiColor,
                lineSpacing: 2
            )
        } else {
            SelectableText(
                markdown: text,
                font: MarkdownText.bodyFont,
                color: textColor.uiColor,
                lineSpacing: 2
            )
        }
    }
}

private struct CodeBlockCopyButton: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = code
            Haptics.impact(.copy)
            Log.ui.info("MarkdownText.copyCodeBlock chars=\(code.count)")
            withAnimation(.easeOut(duration: 0.2)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .frame(width: 22, height: 22)
                .minimumTouchTarget(alignment: .topTrailing)
        }
        .buttonStyle(.plain)
        .disabled(copied)
        .accessibilityLabel(A11yLabel.copyCode)
    }
}

enum MarkdownListKind: Equatable {
    case bullets
    case ordered
}

struct MarkdownListItem: Equatable {
    let text: String
    let children: [MarkdownList]
}

struct MarkdownList: Equatable {
    let kind: MarkdownListKind
    let items: [MarkdownListItem]
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case lists([MarkdownList])
    case code(language: String?, body: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule

    var logShape: String {
        switch self {
        case .paragraph(let text): return "paragraph(chars:\(text.count))"
        case .heading(let level, let text): return "heading(level:\(level),chars:\(text.count))"
        case .lists(let lists): return "lists(groups:\(lists.count),items:\(lists.itemCount),chars:\(lists.characterCount))"
        case .code(let language, let body): return "code(language:\(language ?? "none"),chars:\(body.count))"
        case .quote(let text): return "quote(chars:\(text.count))"
        case .table(let header, let rows): return "table(columns:\(header.count),rows:\(rows.count))"
        case .rule: return "rule"
        }
    }

    private final class Cached { let blocks: [MarkdownBlock]; init(_ blocks: [MarkdownBlock]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Cached> = {
        let c = NSCache<NSString, Cached>()
        c.countLimit = 256
        c.totalCostLimit = TextRenderCachePolicy.parsedLimit
        return c
    }()

    static func parse(_ source: String) -> [MarkdownBlock] {
        let key = TextRenderCachePolicy.key(source)
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parseUncached(source)
        let cost = TextRenderCachePolicy.parsedCost(
            sourceByteCount: source.utf8.count,
            blockCount: blocks.count
        )
        if cost <= cache.totalCostLimit {
            cache.setObject(Cached(blocks), forKey: key, cost: cost)
        }
        return blocks
    }

    static func parseTail(_ source: String) -> [MarkdownBlock] {
        return parseUncached(source)
    }

    private static func parseUncached(_ source: String) -> [MarkdownBlock] {
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

private extension Array where Element == MarkdownList {
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
