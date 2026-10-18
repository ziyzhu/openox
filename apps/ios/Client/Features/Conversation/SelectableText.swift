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

    override func copy(_ sender: Any?) {
        let selection = attributedText.attributedSubstring(from: selectedRange)
        let whole = NSRange(location: 0, length: selection.length)
        let copied = NSMutableString(string: selection.string)
        var markers = 0
        selection.enumerateAttribute(.markdownListMarker, in: whole, options: .reverse) { value, range, _ in
            guard let marker = value as? String else { return }
            copied.replaceCharacters(in: range, with: marker)
            markers += 1
        }
        guard markers > 0 else { return super.copy(sender) }
        UIPasteboard.general.string = copied as String
        Log.ui.info("SelectableText.copy chars=\(copied.length) listMarkers=\(markers)")
    }
}

extension NSAttributedString.Key {
    static let markdownListMarker = NSAttributedString.Key("ai.oxcraft.markdownListMarker")
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
// selection gestures, so the conversation ScrollView and sidebar drag don't steal them.
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    private let streaming: Streaming?
    var fade: Fade?
    @Environment(ServiceManager.self) private var serviceManager
    @Environment(\.conversationLinkHandler) private var conversationLinkHandler

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
        context.coordinator.conversationLinkHandler = conversationLinkHandler
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
        let height = uiView.sizeThatFits(CGSize(width: width, height: unbounded)).height
        let size = CGSize(width: width, height: ceil(height))
        memo.sizes[key] = size
        return size
    }

    static func headingFont(level: Int) -> UIFont {
        let style: UIFont.TextStyle = level <= 1 ? .title3 : (level == 2 ? .headline : .body)
        return UIFont.preferredFont(forTextStyle: style).bold
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(serviceManager: serviceManager, conversationLinkHandler: conversationLinkHandler)
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
        var conversationLinkHandler: ((URL) -> Void)?

        var isStreaming: Bool {
            if case .none = streaming { return false }
            return true
        }

        private enum StreamingState {
            case none
            case plain(utf8Count: Int, resetKey: Int, style: String)
            case attributed(NSAttributedString, resetKey: Int)
        }

        init(serviceManager: ServiceManager, conversationLinkHandler: ((URL) -> Void)?) {
            self.serviceManager = serviceManager
            self.conversationLinkHandler = conversationLinkHandler
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
            if case .textAttachment = textItem.content { return nil }
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
            if case .textAttachment = textItem.content { return nil }
            guard case let .link(url) = textItem.content else {
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            }
            switch ConversationLinkDestination(url) {
            case .web:
                return UITextItem.MenuConfiguration(menu: defaultMenu)
            case .artifact, .file:
                let open = UIAction(title: L10n.string("Open", comment: "Opens a file linked from an assistant message."),
                                    image: UIImage(systemName: "arrow.up.right.circle")) { [weak self] _ in
                    self?.open(url)
                }
                return UITextItem.MenuConfiguration(preview: nil, menu: UIMenu(children: [open]))
            case .unsupported:
                return nil
            }
        }

        private func open(_ url: URL) {
            if let conversationLinkHandler {
                conversationLinkHandler(url)
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
        paragraph.lineBreakStrategy = []
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

    static func attributedMarkdownProse(_ blocks: [MarkdownBlock], color: UIColor, isStreaming: Bool = false)
        -> NSAttributedString {
        let key = TextRenderCachePolicy.key("\(colorKey(color))|\(String(describing: blocks))")
        if !isStreaming, let hit = proseCache.object(forKey: key) { return hit }
        let result = NSMutableAttributedString()
        var previous: MarkdownBlock?
        for block in blocks {
            let gap = previous.map { MarkdownText.spacing(before: block, after: $0) + MarkdownText.headingInset(block) } ?? 0
            appendProse(block, gap: gap, color: color, isStreaming: isStreaming, to: result)
            previous = block
        }
        let rendered = NSAttributedString(attributedString: result)
        let cost = TextRenderCachePolicy.attributedCost(utf16Count: rendered.length)
        if !isStreaming, cost <= proseCache.totalCostLimit {
            proseCache.setObject(rendered, forKey: key, cost: cost)
        }
        return rendered
    }

    private static func appendProse(
        _ block: MarkdownBlock,
        gap: CGFloat,
        color: UIColor,
        isStreaming: Bool,
        to result: NSMutableAttributedString
    ) {
        let text = { (source: String) in isStreaming ? StreamingMarkdownText.balanced(source) : source }
        switch block {
        case .paragraph(let source):
            let rendered = renderMarkdown(text(source), font: MarkdownText.bodyFont, color: color, lineSpacing: 1)
            appendParagraph(rendered, gap: gap, to: result) { $0.lineSpacing = 1 }
        case .heading(let level, let source):
            let rendered = renderMarkdown(text(source), font: headingFont(level: level), color: color, lineSpacing: 2)
            appendParagraph(rendered, gap: gap, to: result) { $0.lineSpacing = 2 }
        case .lists(let lists):
            appendLists(lists, depth: 0, gap: gap, color: color, text: text, to: result)
        case .code, .quote, .table, .rule, .embed:
            break
        }
    }

    private static func appendLists(
        _ lists: [MarkdownList],
        depth: Int,
        gap: CGFloat,
        color: UIColor,
        text: (String) -> String,
        to result: NSMutableAttributedString
    ) {
        let itemSpacing: CGFloat = 3
        var gap = gap
        for list in lists {
            let indent = CGFloat(depth) * Theme.Spacing.lg
            let markerWidth = listMarkerWidth(list.kind)
            let markerOverhang = listMarkerOverhang(list.kind)
            for (index, item) in list.items.enumerated() {
                let line = NSMutableAttributedString(attributedString: listMarker(list.kind, index: index, depth: depth, color: color))
                line.append(renderMarkdown(text(item.text), font: MarkdownText.bodyFont, color: color, lineSpacing: 2))
                appendParagraph(line, gap: gap + markerOverhang, to: result) { style in
                    style.lineSpacing = 2
                    style.firstLineHeadIndent = indent
                    style.headIndent = indent + markerWidth + Theme.Spacing.sm
                    style.tabStops = [
                        NSTextTab(textAlignment: .right, location: indent + markerWidth),
                        NSTextTab(textAlignment: .left, location: indent + markerWidth + Theme.Spacing.sm),
                    ]
                }
                gap = itemSpacing
                appendLists(item.children, depth: depth + 1, gap: itemSpacing, color: color, text: text, to: result)
            }
        }
    }

    private static func appendParagraph(
        _ paragraph: NSAttributedString,
        gap: CGFloat,
        to result: NSMutableAttributedString,
        configure: (NSMutableParagraphStyle) -> Void
    ) {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = []
        configure(style)
        if result.length > 0 {
            let previous = result.attribute(.paragraphStyle, at: result.length - 1, effectiveRange: nil) as? NSParagraphStyle
            style.paragraphSpacingBefore = max(0, gap - style.lineSpacing)
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: MarkdownText.bodyFont,
                .paragraphStyle: previous ?? style,
            ]))
        }
        let styled = NSMutableAttributedString(attributedString: paragraph)
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
        result.append(styled)
    }

    private static let bulletFont = UIFont.monospacedDigitSystemFont(
        ofSize: MarkdownText.bodyFont.pointSize * 1.35, weight: .regular
    )
    private static let orderedMarkerFont = UIFont.monospacedDigitSystemFont(
        ofSize: MarkdownText.bodyFont.pointSize, weight: .regular
    )

    static func proseTopInset(_ block: MarkdownBlock) -> CGFloat {
        guard case .lists(let lists) = block else { return MarkdownText.headingInset(block) }
        return lists.first.map { listMarkerOverhang($0.kind) } ?? 0
    }

    private static func listMarkerOverhang(_ kind: MarkdownListKind) -> CGFloat {
        kind == .bullets ? bulletFont.ascender - MarkdownText.bodyFont.ascender : 0
    }

    private static func listMarkerWidth(_ kind: MarkdownListKind) -> CGFloat {
        let (marker, font) = kind == .ordered ? ("99.", orderedMarkerFont) : ("•", bulletFont)
        return ceil((marker as NSString).size(withAttributes: [.font: font]).width)
    }

    private static var bullets: [String: NSTextAttachment] = [:]

    private static func bullet(color: UIColor) -> NSTextAttachment {
        let styles: [UIUserInterfaceStyle] = [.light, .dark]
        let key = styles.map { colorKey(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: $0))) }.joined(separator: "|")
        if let cached = bullets[key] { return cached }
        let inkTop = CTLineGetImageBounds(
            CTLineCreateWithAttributedString(NSAttributedString(string: "•", attributes: [.font: bulletFont])), nil
        ).maxY
        let size = CGSize(width: ("•" as NSString).size(withAttributes: [.font: bulletFont]).width, height: ceil(inkTop))
        let asset = UIImageAsset()
        for style in styles {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let glyph = NSAttributedString(string: "•", attributes: [
                .font: bulletFont,
                .foregroundColor: color.resolvedColor(with: traits),
            ])
            let format = UIGraphicsImageRendererFormat(for: traits)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                glyph.draw(at: CGPoint(x: 0, y: size.height - bulletFont.ascender))
            }
            asset.register(image, with: traits)
        }
        let attachment = NSTextAttachment(image: asset.image(with: UITraitCollection.current))
        attachment.bounds = CGRect(origin: .zero, size: size)
        bullets[key] = attachment
        return attachment
    }

    private static func listMarker(_ kind: MarkdownListKind, index: Int, depth: Int, color: UIColor) -> NSAttributedString {
        let copied = String(repeating: "  ", count: depth) + (kind == .ordered ? "\(index + 1). " : "• ")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: MarkdownText.bodyFont,
            .foregroundColor: color,
            .markdownListMarker: copied,
        ]
        let marker = NSMutableAttributedString(string: "\t", attributes: attributes)
        switch kind {
        case .bullets:
            let bullet = NSMutableAttributedString(attachment: bullet(color: color))
            bullet.addAttributes(attributes, range: NSRange(location: 0, length: bullet.length))
            marker.append(bullet)
        case .ordered:
            marker.append(NSAttributedString(
                string: "\(index + 1).",
                attributes: attributes.merging([.font: orderedMarkerFont]) { $1 }
            ))
        }
        marker.append(NSAttributedString(string: "\t", attributes: attributes))
        return marker
    }

    private static let proseCache: NSCache<NSString, NSAttributedString> = {
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
                    attributes[.foregroundColor] = Theme.Colors.conversationInlineCode.uiColor
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
