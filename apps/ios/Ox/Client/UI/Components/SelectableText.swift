import SwiftUI
import UIKit

enum SelectableTextSelection {
    static var isActive: Bool {
        SelectableTextView.activeSelection?.selectedRange.length ?? 0 > 0
    }

    static func dismiss() -> Bool {
        guard let view = SelectableTextView.activeSelection, view.selectedRange.length > 0 else { return false }
        view.dismissSelection()
        return true
    }
}

private final class SelectableTextView: UITextView {
    fileprivate static weak var activeSelection: SelectableTextView?

    func dismissSelection() {
        let range = selectedRange
        guard range.location != NSNotFound, range.length > 0 else { return }
        selectedRange = NSRange(location: range.location, length: 0)
        resignFirstResponder()
        Log.ui.info("SelectableText.dismissSelection chars=\(range.length)")
    }
}

private struct SelectableTextSelectionDismissModifier: ViewModifier {
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            TapGesture()
                .onEnded {
                    guard SelectableTextSelection.dismiss() else { return }
                    onDismiss()
                }
        )
    }
}

extension View {
    func dismissesSelectableTextSelection(perform onDismiss: @escaping () -> Void) -> some View {
        modifier(SelectableTextSelectionDismissModifier(onDismiss: onDismiss))
    }
}

// SwiftUI's `.textSelection(.enabled)` only copies a whole Text at once on iOS
// (no loupe, no partial range) and is unreliable inside a ScrollView on iOS 18.
// A non-editable UITextView gives real cursor/range selection and owns its own
// selection gestures, so the chat ScrollView and sidebar drag don't steal them.
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    private let streaming: Streaming?
    var fade: Fade?
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.chatLinkHandler) private var chatLinkHandler

    fileprivate struct StreamingPlain {
        let source: String
        let resetKey: Int
        let font: UIFont
        let color: UIColor
        let lineSpacing: CGFloat
    }

    fileprivate struct StreamingAttributed {
        let value: NSAttributedString
        let resetKey: Int
    }

    private enum Streaming {
        case plain(StreamingPlain)
        case attributed(StreamingAttributed)
    }

    // Fading recolors ranges in place on the text view's storage: color-only
    // attribute edits redraw without relayout, so fade ticks never invalidate
    // layout or size. Replacing attributedText per tick would relayout at 30fps.
    struct Fade {
        let color: UIColor?
        let arrivals: [StreamingFadeText.Arrival]
        let now: CFTimeInterval
    }

    init(_ attributed: NSAttributedString, fade: Fade? = nil) {
        self.attributed = attributed
        streaming = nil
        self.fade = fade
    }

    init(plain text: String, font: UIFont, color: UIColor, lineSpacing: CGFloat = 0) {
        self.attributed = NSAttributedString(
            string: text,
            attributes: SelectableText.baseAttributes(font: font, color: color, lineSpacing: lineSpacing)
        )
        streaming = nil
    }

    init(
        streamingPlain text: String,
        resetKey: Int,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat = 0,
        fade: Fade? = nil
    ) {
        attributed = NSAttributedString()
        streaming = .plain(StreamingPlain(
            source: text,
            resetKey: resetKey,
            font: font,
            color: color,
            lineSpacing: lineSpacing
        ))
        self.fade = fade
    }

    init(
        streamingAttributed value: NSAttributedString,
        resetKey: Int,
        fade: Fade? = nil
    ) {
        attributed = value
        streaming = .attributed(StreamingAttributed(value: value, resetKey: resetKey))
        self.fade = fade
    }

    init(markdown source: String, font: UIFont, color: UIColor, lineSpacing: CGFloat = 0) {
        self.attributed = SelectableText.renderMarkdown(source, font: font, color: color, lineSpacing: lineSpacing)
        streaming = nil
    }

    init(code source: String, language: String?) {
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular
        )
        attributed = SyntaxHighlighter.selectable(source, language: language, font: font)
        streaming = nil
    }

    func makeUIView(context: Context) -> UITextView {
        let view = SelectableTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = linkTextAttributes
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        let dismissTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = context.coordinator
        view.addGestureRecognizer(dismissTap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.chatLinkHandler = chatLinkHandler
        switch streaming {
        case .plain(let streamingPlain):
            context.coordinator.updateStreamingPlain(streamingPlain, in: view)
        case .attributed(let streamingAttributed):
            context.coordinator.updateStreamingAttributed(streamingAttributed, in: view)
        case nil:
            context.coordinator.endStreaming()
            if context.coordinator.lastSet !== attributed {
                view.linkTextAttributes = linkTextAttributes
                view.attributedText = attributed
                context.coordinator.textReplaced(attributed)
            }
        }
        guard let fade else { return }
        context.coordinator.fadedStart = applyFade(
            fade,
            to: view.textStorage,
            previousStart: context.coordinator.fadedStart
        )
    }

    private func applyFade(
        _ fade: Fade,
        to storage: NSTextStorage,
        previousStart: Int?
    ) -> Int? {
        let length = fade.color == nil
            ? min(storage.length, attributed.length)
            : storage.length
        guard length > 0 else { return nil }
        var firstLive = 0
        while firstLive < fade.arrivals.count,
              fade.now - fade.arrivals[firstLive].timestamp >= Theme.Animation.streamFade {
            firstLive += 1
        }
        let live = fade.arrivals[firstLive...]
        let liveStart = live.first.map { min($0.startIndex, length) }
        let dirtyStart = min(previousStart ?? length, liveStart ?? length)
        guard dirtyStart < length else { return liveStart }
        storage.beginEditing()
        let dirtyRange = NSRange(location: dirtyStart, length: length - dirtyStart)
        if let color = fade.color {
            storage.addAttribute(.foregroundColor, value: color, range: dirtyRange)
        } else {
            applyColors(from: attributed, to: storage, range: dirtyRange)
        }
        for index in live.indices {
            let arrival = live[index]
            let next = live.index(after: index)
            let end = min(next < live.endIndex ? live[next].startIndex : length, length)
            let start = min(arrival.startIndex, length)
            guard end > start else { continue }
            let opacity = CGFloat(StreamingFadeText.opacity(
                at: fade.now,
                since: arrival.timestamp,
                duration: Theme.Animation.streamFade
            ))
            let range = NSRange(location: start, length: end - start)
            if let color = fade.color {
                storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(opacity), range: range)
            } else {
                applyColors(from: attributed, to: storage, range: range, alpha: opacity)
            }
        }
        storage.endEditing()
        return liveStart
    }

    private var linkTextAttributes: [NSAttributedString.Key: Any] {
        let color = attributed.length > 0
            ? attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor ?? UIColor.label
            : UIColor.label
        return [
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
        ]
    }

    private func applyColors(
        from source: NSAttributedString,
        to storage: NSTextStorage,
        range: NSRange,
        alpha: CGFloat? = nil
    ) {
        source.enumerateAttribute(.foregroundColor, in: range) { value, colorRange, _ in
            let color = value as? UIColor ?? .label
            storage.addAttribute(
                .foregroundColor,
                value: alpha.map { color.withAlphaComponent($0) } ?? color,
                range: colorRange
            )
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let unbounded: CGFloat = 100_000
        let maxWidth = proposal.width ?? unbounded
        let memo = context.coordinator
        let key = Coordinator.SizeKey(width: maxWidth, category: uiView.traitCollection.preferredContentSizeCategory)
        if let cached = memo.sizes[key] { return cached }
        let width = proposal.width ?? ceil(uiView.sizeThatFits(CGSize(width: unbounded, height: unbounded)).width)
        let height: CGFloat
        if memo.isStreaming {
            let containerWidth = max(0, width - uiView.textContainerInset.left - uiView.textContainerInset.right)
            let containerSize = CGSize(width: containerWidth, height: unbounded)
            if uiView.textContainer.size != containerSize {
                uiView.textContainer.size = containerSize
            }
            uiView.layoutManager.ensureLayout(for: uiView.textContainer)
            let used = uiView.layoutManager.usedRect(for: uiView.textContainer)
            height = used.maxY + uiView.textContainerInset.bottom
        } else {
            height = uiView.sizeThatFits(CGSize(width: width, height: unbounded)).height
        }
        let size = CGSize(width: width, height: ceil(height))
        memo.sizes[key] = size
        return size
    }

    static func headingFont(level: Int) -> UIFont {
        let style: UIFont.TextStyle = level <= 1 ? .title3 : (level == 2 ? .headline : .body)
        return UIFont.preferredFont(forTextStyle: style).bold
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(serviceManager: serviceManager, chatLinkHandler: chatLinkHandler)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        struct SizeKey: Hashable {
            let width: CGFloat
            let category: UIContentSizeCategory
        }

        var lastSet: NSAttributedString?
        var sizes: [SizeKey: CGSize] = [:]
        private let serviceManager: ServiceManager
        var fadedStart: Int?
        private var streaming = StreamingState.none
        var chatLinkHandler: ((URL) -> Void)?

        var isStreaming: Bool {
            if case .none = streaming { return false }
            return true
        }

        private enum StreamingState {
            case none
            case plain(utf8Count: Int, resetKey: Int, style: String)
            case attributed(NSAttributedString, resetKey: Int)
        }

        init(serviceManager: ServiceManager, chatLinkHandler: ((URL) -> Void)?) {
            self.serviceManager = serviceManager
            self.chatLinkHandler = chatLinkHandler
        }

        func textReplaced(_ attributed: NSAttributedString) {
            lastSet = attributed
            fadedStart = nil
            sizes.removeAll()
        }

        fileprivate func updateStreamingPlain(_ stream: StreamingPlain, in view: UITextView) {
            let style = SelectableText.styleKey(font: stream.font, color: stream.color, lineSpacing: stream.lineSpacing)
            let attributes = SelectableText.baseAttributes(
                font: stream.font,
                color: stream.color,
                lineSpacing: stream.lineSpacing
            )
            let total = stream.source.utf8.count
            guard case let .plain(previousCount, resetKey, previousStyle) = streaming,
                  previousStyle == style,
                  resetKey == stream.resetKey,
                  total >= previousCount else {
                let rendered = NSAttributedString(string: stream.source, attributes: attributes)
                view.attributedText = rendered
                streaming = .plain(utf8Count: total, resetKey: stream.resetKey, style: style)
                textReplaced(rendered)
                return
            }
            guard total > previousCount else { return }
            let delta = String(decoding: stream.source.utf8.suffix(total - previousCount), as: UTF8.self)
            view.textStorage.append(NSAttributedString(string: delta, attributes: attributes))
            streaming = .plain(utf8Count: total, resetKey: stream.resetKey, style: style)
            sizes.removeAll()
        }

        fileprivate func updateStreamingAttributed(_ stream: StreamingAttributed, in view: UITextView) {
            let next = stream.value
            guard case let .attributed(previous, resetKey) = streaming,
                  resetKey == stream.resetKey else {
                replaceStreamedAttributed(next, resetKey: stream.resetKey, in: view)
                return
            }
            if next.isEqual(to: previous) { return }
            guard next.length > previous.length,
                  next.attributedSubstring(from: NSRange(location: 0, length: previous.length)).isEqual(to: previous) else {
                replaceStreamedAttributed(next, resetKey: stream.resetKey, in: view)
                return
            }
            let delta = next.attributedSubstring(
                from: NSRange(location: previous.length, length: next.length - previous.length)
            )
            view.textStorage.append(delta)
            streaming = .attributed(next, resetKey: stream.resetKey)
            lastSet = next
            sizes.removeAll()
        }

        func endStreaming() {
            let wasStreaming = isStreaming
            streaming = .none
            if wasStreaming { sizes.removeAll() }
        }

        private func replaceStreamedAttributed(
            _ attributed: NSAttributedString,
            resetKey: Int,
            in view: UITextView
        ) {
            view.attributedText = attributed
            streaming = .attributed(attributed, resetKey: resetKey)
            textReplaced(attributed)
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            return UIAction { [weak self] _ in
                self?.open(url)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let textView = textView as? SelectableTextView else { return }
            if textView.selectedRange.length > 0 {
                SelectableTextView.activeSelection = textView
            } else if SelectableTextView.activeSelection === textView {
                SelectableTextView.activeSelection = nil
            }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                      defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            guard case let .link(url) = textItem.content else {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            switch ChatLinkDestination(url) {
            case .web:
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            case .artifact:
                let open = UIAction(title: L10n.string("Open", comment: "Opens an artifact linked from an assistant message."),
                                    image: UIImage(systemName: "arrow.up.right.circle")) { [weak self] _ in
                    self?.open(url)
                }
                return UITextItem.MenuConfiguration(preview: nil, menu: UIMenu(children: [open]))
            case .unsupported:
                return nil
            }
        }

        private func open(_ url: URL) {
            if let chatLinkHandler {
                chatLinkHandler(url)
            } else {
                LinkOpener.open(url: url, serviceManager: serviceManager)
            }
        }

        @objc func dismissKeyboard(_ gesture: UITapGestureRecognizer) {
            guard let textView = gesture.view as? UITextView else { return }
            guard textView.selectedRange.length == 0 else {
                Log.ui.info("SelectableText.keepSelection chars=\(textView.selectedRange.length)")
                return
            }
            guard textView.window?.endEditing(true) == true else { return }
            Log.ui.info("SelectableText.dismissKeyboard via=transcriptTextTap")
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    private static func baseAttributes(font: UIFont, color: UIColor, lineSpacing: CGFloat)
        -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakStrategy = .pushOut
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private static let cache: NSCache<NSString, NSAttributedString> = {
        let c = NSCache<NSString, NSAttributedString>()
        c.countLimit = 512
        c.totalCostLimit = TextRenderCachePolicy.attributedLimit
        return c
    }()

    private final class ParsedMarkdown {
        let attributed: AttributedString?

        init(_ source: String) {
            attributed = try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }
    }

    private static let parsedMarkdownCache: NSCache<NSString, ParsedMarkdown> = {
        let cache = NSCache<NSString, ParsedMarkdown>()
        cache.countLimit = 512
        cache.totalCostLimit = TextRenderCachePolicy.parsedLimit
        return cache
    }()

    private static func colorKey(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return "\(r),\(g),\(b),\(a)"
    }

    private static func styleKey(font: UIFont, color: UIColor, lineSpacing: CGFloat) -> String {
        "\(font.pointSize)|\(font.fontName)|\(lineSpacing)|\(colorKey(color))"
    }

    private struct StreamCacheEntry {
        let style: String
        let key: NSString
        let sourceByteCount: Int
    }

    private static var lastStreamEntry: StreamCacheEntry?

    static func attributedMarkdown(_ source: String, font: UIFont, color: UIColor, lineSpacing: CGFloat)
        -> NSAttributedString {
        renderMarkdown(source, font: font, color: color, lineSpacing: lineSpacing)
    }

    static func inlineMarkdown(_ source: String) -> AttributedString? {
        parsedMarkdown(source).attributed
    }

    static func attributedMarkdownParagraphs(
        _ sources: [String],
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> NSAttributedString {
        let style = "\(styleKey(font: font, color: color, lineSpacing: lineSpacing))|\(paragraphSpacing)"
        let sourceKey = sources.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let key = TextRenderCachePolicy.key("\(style)|\(sourceKey)")
        if let hit = paragraphCache.object(forKey: key) { return hit }
        let result = NSMutableAttributedString()
        for (index, source) in sources.enumerated() {
            let paragraph = NSMutableAttributedString(
                attributedString: renderMarkdown(source, font: font, color: color, lineSpacing: lineSpacing)
            )
            if index < sources.count - 1 {
                paragraph.append(NSAttributedString(string: "\n"))
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.lineBreakStrategy = .pushOut
            style.paragraphSpacing = index < sources.count - 1 ? max(0, paragraphSpacing - lineSpacing) : 0
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            result.append(paragraph)
        }
        let rendered = NSAttributedString(attributedString: result)
        let cost = TextRenderCachePolicy.attributedCost(utf16Count: rendered.length)
        if cost <= paragraphCache.totalCostLimit {
            paragraphCache.setObject(rendered, forKey: key, cost: cost)
        }
        return rendered
    }

    private static let paragraphCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 256
        cache.totalCostLimit = TextRenderCachePolicy.attributedLimit
        return cache
    }()

    private static func renderMarkdown(_ source: String, font: UIFont, color: UIColor, lineSpacing: CGFloat)
        -> NSAttributedString {
        let style = styleKey(font: font, color: color, lineSpacing: lineSpacing)
        let key = TextRenderCachePolicy.key("\(style)|\(source)")
        if let hit = cache.object(forKey: key) { return hit }
        let rendered = buildMarkdown(source, font: font, color: color, lineSpacing: lineSpacing)
        if let last = lastStreamEntry,
           last.style == style,
           source.utf8.count > last.sourceByteCount {
            let prefix = String(decoding: source.utf8.prefix(last.sourceByteCount), as: UTF8.self)
            if TextRenderCachePolicy.key("\(style)|\(prefix)").isEqual(last.key) {
                cache.removeObject(forKey: last.key)
            }
        }
        let cost = TextRenderCachePolicy.attributedCost(utf16Count: rendered.length)
        if cost <= cache.totalCostLimit {
            cache.setObject(rendered, forKey: key, cost: cost)
            lastStreamEntry = StreamCacheEntry(style: style, key: key, sourceByteCount: source.utf8.count)
        } else {
            lastStreamEntry = nil
        }
        return rendered
    }

    private static func buildMarkdown(_ source: String, font: UIFont, color: UIColor, lineSpacing: CGFloat)
        -> NSAttributedString {
        let base = baseAttributes(font: font, color: color, lineSpacing: lineSpacing)
        guard let parsed = inlineMarkdown(source) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var attributes = base
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { attributes[.font] = font.bold }
                if intent.contains(.code) {
                    attributes[.foregroundColor] = Theme.Colors.onSurfaceMuted.uiColor
                }
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func parsedMarkdown(_ source: String) -> ParsedMarkdown {
        let key = TextRenderCachePolicy.key(source)
        if let cached = parsedMarkdownCache.object(forKey: key) { return cached }
        let parsed = ParsedMarkdown(source)
        let cost = TextRenderCachePolicy.parsedCost(sourceByteCount: source.utf8.count)
        if cost <= parsedMarkdownCache.totalCostLimit {
            parsedMarkdownCache.setObject(parsed, forKey: key, cost: cost)
        }
        return parsed
    }
}

private extension UIFont {
    var bold: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitBold)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
