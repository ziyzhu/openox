import QuartzCore
import SwiftUI
import UIKit

struct StreamingFadeText: View {
    let text: AttributedString
    var resetKey = 0
    var font: Font = .body
    var lineSpacing: CGFloat = 3
    var color: Color? = nil

    struct Arrival: Equatable {
        let startIndex: Int
        let timestamp: CFTimeInterval
    }

    struct Tracker {
        private(set) var arrivals: [Arrival] = []
        private var renderedLength = 0
        private var reset = Int.min
        private var lastUpdateTimestamp: CFTimeInterval?

        mutating func absorb(
            _ length: Int,
            reset nextReset: Int,
            at now: CFTimeInterval,
            characterStarts: [Int]? = nil
        ) -> CFTimeInterval? {
            if reset != nextReset {
                reset = nextReset
                arrivals.removeAll()
                renderedLength = 0
                lastUpdateTimestamp = nil
            }
            if length > renderedLength {
                let starts = characterStarts.map {
                    let fresh = $0.filter { $0 >= renderedLength && $0 < length }
                    return fresh.isEmpty ? [renderedLength] : fresh
                } ?? Array(renderedLength..<length)
                let frameDuration = lastUpdateTimestamp.map {
                    min(1.0 / 15.0, max(1.0 / 120.0, now - $0))
                } ?? 1.0 / 30.0
                let interval = frameDuration / Double(max(1, starts.count))
                for (offset, startIndex) in starts.enumerated() {
                    arrivals.append(Arrival(
                        startIndex: startIndex,
                        timestamp: now - frameDuration + interval * Double(offset + 1)
                    ))
                }
                lastUpdateTimestamp = now
            } else if length < renderedLength {
                arrivals.removeAll()
                lastUpdateTimestamp = nil
            }
            renderedLength = length
            while let first = arrivals.first,
                  first.timestamp + Theme.Animation.streamFade <= now {
                arrivals.removeFirst()
            }
            return arrivals.last.map { $0.timestamp + Theme.Animation.streamFade }
        }

        mutating func settle() {
            arrivals.removeAll()
        }
    }

    private struct Marker: Equatable {
        let reset: Int
        let count: Int
    }

    @State private var tracker = Tracker()
    @State private var fadeDeadline: CFTimeInterval?
    @State private var settleTask: Task<Void, Never>?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: fadeDeadline == nil)) { _ in
            Text(text)
                .font(font)
                .lineSpacing(lineSpacing)
                .foregroundStyle(color.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .textRenderer(StreamingChunkFade(
                    now: CACurrentMediaTime(),
                    arrivals: tracker.arrivals,
                    duration: Theme.Animation.streamFade
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: Marker(reset: resetKey, count: text.characters.count), initial: true) { _, marker in
            absorb(marker.count, reset: marker.reset)
        }
        .onDisappear { settleTask?.cancel() }
    }

    private func absorb(_ count: Int, reset: Int) {
        let now = CACurrentMediaTime()
        let deadline = tracker.absorb(count, reset: reset, at: now)
        settleTask?.cancel()
        guard let deadline else {
            fadeDeadline = nil
            return
        }
        fadeDeadline = deadline
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled else { return }
            tracker.settle()
            fadeDeadline = nil
        }
    }

    static func opacity(at now: CFTimeInterval, since timestamp: CFTimeInterval, duration: Double) -> Double {
        let progress = min(1, max(0, (now - timestamp) / duration))
        let remaining = 1 - progress
        return 1 - remaining * remaining
    }
}

struct StreamingFadeSelectableText: View {
    private enum Content {
        case markdown(String)
        case code(String, language: String?)

        var source: String {
            switch self {
            case .markdown(let source), .code(let source, _): source
            }
        }

        var streamsPlain: Bool {
            if case .code = self { return true }
            return false
        }

        func attributed(font: UIFont, color: UIColor, lineSpacing: CGFloat) -> NSAttributedString {
            switch self {
            case .markdown(let source):
                SelectableText.attributedMarkdown(source, font: font, color: color, lineSpacing: lineSpacing)
            case .code(let source, let language):
                SyntaxHighlighter.selectable(source, language: language, font: font)
            }
        }
    }

    private let content: Content
    var resetKey = 0
    let font: UIFont
    let color: UIColor
    var lineSpacing: CGFloat = 3

    private struct Marker: Equatable {
        let reset: Int
        let length: Int
    }

    @State private var tracker = StreamingFadeText.Tracker()
    @State private var fadeDeadline: CFTimeInterval?
    @State private var settleTask: Task<Void, Never>?
    @State private var classifier = InlineClassifier()

    init(
        markdown: String,
        resetKey: Int = 0,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat = 3
    ) {
        content = .markdown(markdown)
        self.resetKey = resetKey
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
    }

    init(code: String, language: String?, resetKey: Int = 0) {
        content = .code(code, language: language)
        self.resetKey = resetKey
        font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
        color = .label
        lineSpacing = 0
    }

    var body: some View {
        let source = content.source
        let streamsPlain = content.streamsPlain
        let plain = streamsPlain || classifier.isPlain(source, reset: resetKey)
        let rendered = plain ? nil : content.attributed(font: font, color: color, lineSpacing: lineSpacing)
        let length = streamsPlain ? source.utf16.count : (plain ? classifier.length : rendered?.length ?? 0)
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: fadeDeadline == nil)) { _ in
            let now = CACurrentMediaTime()
            if plain {
                SelectableText(
                    streamingPlain: source,
                    resetKey: resetKey,
                    font: font,
                    color: color,
                    lineSpacing: lineSpacing,
                    fade: .init(color: color, arrivals: tracker.arrivals, now: now)
                )
            } else if let rendered {
                SelectableText(
                    rendered,
                    fade: .init(
                        color: color,
                        arrivals: tracker.arrivals,
                        now: now
                    )
                )
            }
        }
        .onChange(of: Marker(reset: resetKey, length: length), initial: true) { _, marker in
            absorb(
                marker.length,
                reset: marker.reset,
                characterStarts: plain && !streamsPlain ? classifier.freshCharacterStarts : []
            )
        }
        .onDisappear { settleTask?.cancel() }
    }

    private final class InlineClassifier {
        private var consumedUTF8 = 0
        private var previousSource = ""
        private var reset = Int.min
        private var plain = true
        private(set) var length = 0
        private(set) var freshCharacterStarts: [Int] = []

        func isPlain(_ source: String, reset nextReset: Int) -> Bool {
            freshCharacterStarts.removeAll(keepingCapacity: true)
            let total = source.utf8.count
            let needsReset = reset != nextReset
                || (plain && (total < consumedUTF8 || !source.hasPrefix(previousSource)))
            if needsReset {
                reset = nextReset
                consumedUTF8 = 0
                plain = true
                length = 0
            }
            previousSource = source
            guard plain, total > consumedUTF8 else { return plain }
            let delta = String(decoding: source.utf8.suffix(total - consumedUTF8), as: UTF8.self)
            consumedUTF8 = total
            var remainsPlain = true
            for character in delta {
                freshCharacterStarts.append(length)
                length += String(character).utf16.count
                if "*_`[\\<>".contains(character) { remainsPlain = false }
            }
            plain = remainsPlain
            return plain
        }
    }

    private func absorb(_ length: Int, reset: Int, characterStarts: [Int]) {
        let now = CACurrentMediaTime()
        let deadline = tracker.absorb(
            length,
            reset: reset,
            at: now,
            characterStarts: characterStarts
        )
        settleTask?.cancel()
        guard let deadline else {
            fadeDeadline = nil
            return
        }
        fadeDeadline = deadline
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled else { return }
            tracker.settle()
            fadeDeadline = nil
        }
    }
}

struct StreamingChunkFade: TextRenderer {
    let now: CFTimeInterval
    let arrivals: [StreamingFadeText.Arrival]
    let duration: Double

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        var index = 0
        var arrivalIndex = 0
        for slice in layout.flatMap({ $0 }).flatMap({ $0 }) {
            defer { index += 1 }
            while arrivalIndex + 1 < arrivals.count,
                  arrivals[arrivalIndex + 1].startIndex <= index {
                arrivalIndex += 1
            }
            guard arrivalIndex < arrivals.count,
                  arrivals[arrivalIndex].startIndex <= index else {
                ctx.draw(slice)
                continue
            }
            let opacity = StreamingFadeText.opacity(
                at: now,
                since: arrivals[arrivalIndex].timestamp,
                duration: duration
            )
            if opacity >= 1 {
                ctx.draw(slice)
            } else {
                var faded = ctx
                faded.opacity = opacity
                faded.draw(slice)
            }
        }
    }
}
