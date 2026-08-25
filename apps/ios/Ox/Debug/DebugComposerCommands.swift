#if targetEnvironment(simulator)
import Foundation
import UIKit
import UniformTypeIdentifiers

extension DebugUIAPI {
    @MainActor
    static func handleSetComposerDraft(_ command: PromptRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let composer else {
            reply(encode(StatusResult(kind: "set-composer-draft-result", id: command.id, error: "composer unavailable")))
            return
        }
        composer.draft = command.prompt
        reply(encode(StatusResult(kind: "set-composer-draft-result", id: command.id)))
    }

    @MainActor
    static func handleSetComposerMarkedText(
        _ command: PromptRequest,
        reply: @escaping @MainActor (Data) -> Void
    ) {
        guard let textView = visibleComposerTextViews().first else {
            reply(encode(StatusResult(
                kind: "set-composer-marked-text-result",
                id: command.id,
                error: "composer text view unavailable"
            )))
            return
        }
        textView.setMarkedText(
            command.prompt,
            selectedRange: NSRange(location: command.prompt.utf16.count, length: 0)
        )
        reply(encode(StatusResult(kind: "set-composer-marked-text-result", id: command.id)))
    }

    @MainActor
    static func handleGetComposerFormatting(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
        let draft = composer?.attributedDraft ?? AttributedString()
        let textViews = visibleComposerTextViews()
            .filter { $0.window != nil && !$0.isHidden && $0.alpha > 0 && $0.text == String(draft.characters) }
        reply(encode(ComposerFormattingResult(
            id: command.id,
            ok: true,
            text: String(draft.characters),
            hasForegroundColor: draft.runs.contains { $0.foregroundColor != nil },
            visibleHasOrangeForeground: textViews.contains(where: containsOrangeForeground),
            visibleHasPrimaryForeground: textViews.contains(where: containsPrimaryForeground),
            visibleHasMarkedText: textViews.contains { $0.markedTextRange != nil }
        )))
    }

    @MainActor
    static func visibleComposerTextViews() -> [UITextView] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .compactMap { $0.rootViewController?.view }
            .flatMap(textViews)
            .filter { $0.accessibilityIdentifier == A11yID.Chat.input }
    }

    @MainActor
    static func textViews(in view: UIView) -> [UITextView] {
        let current = (view as? UITextView).map { [$0] } ?? []
        return current + view.subviews.flatMap(textViews)
    }

    @MainActor
    static func containsOrangeForeground(in textView: UITextView) -> Bool {
        containsForeground(UIColor.systemOrange, in: textView)
    }

    @MainActor
    static func containsPrimaryForeground(in textView: UITextView) -> Bool {
        containsForeground(Theme.Colors.primary.uiColor, in: textView)
    }

    @MainActor
    static func containsForeground(_ expected: UIColor, in textView: UITextView) -> Bool {
        let range = NSRange(location: 0, length: textView.attributedText.length)
        var found = false
        let expected = expected.resolvedColor(with: textView.traitCollection)
        textView.attributedText.enumerateAttribute(.foregroundColor, in: range) { value, _, stop in
            guard let color = (value as? UIColor)?.resolvedColor(with: textView.traitCollection) else { return }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            var expectedRed: CGFloat = 0
            var expectedGreen: CGFloat = 0
            var expectedBlue: CGFloat = 0
            var expectedAlpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
                  expected.getRed(
                    &expectedRed,
                    green: &expectedGreen,
                    blue: &expectedBlue,
                    alpha: &expectedAlpha
                  ),
                  abs(red - expectedRed) < 0.05,
                  abs(green - expectedGreen) < 0.05,
                  abs(blue - expectedBlue) < 0.05 else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    @MainActor
    static func handleSetPasteboardImage(_ command: IDRequest, reply: @escaping @MainActor (Data) -> Void) {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        guard let data = image.pngData() else {
            reply(encode(StatusResult(kind: "set-pasteboard-image-result", id: command.id, error: "image encoding failed")))
            return
        }
        UIPasteboard.general.items = [[UTType.png.identifier: data]]
        reply(encode(StatusResult(kind: "set-pasteboard-image-result", id: command.id)))
    }

    @MainActor
    static func handleSetPasteboardRichText(_ command: PromptRequest, reply: @escaping @MainActor (Data) -> Void) {
        let source = NSAttributedString(
            string: command.prompt,
            attributes: [.foregroundColor: UIColor.systemOrange]
        )
        guard let data = try? source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            reply(encode(StatusResult(kind: "set-pasteboard-rich-text-result", id: command.id, error: "RTF encoding failed")))
            return
        }
        UIPasteboard.general.items = [[
            UTType.rtf.identifier: data,
            UTType.plainText.identifier: command.prompt,
        ]]
        reply(encode(StatusResult(kind: "set-pasteboard-rich-text-result", id: command.id)))
    }

    @MainActor
    static func handleStageSharedNote(_ command: PromptRequest, reply: @escaping @MainActor (Data) -> Void) {
        do {
            try SharedNoteInbox.stageForTesting(title: "Shared Note Test", text: command.prompt)
            reply(encode(StatusResult(kind: "stage-shared-note-result", id: command.id)))
        } catch {
            reply(encode(StatusResult(
                kind: "stage-shared-note-result",
                id: command.id,
                error: error.localizedDescription
            )))
        }
    }

    @MainActor
    static func handleSetEditDraft(_ command: PromptRequest, reply: @escaping @MainActor (Data) -> Void) {
        guard let setEditDraft else {
            reply(encode(StatusResult(kind: "set-edit-draft-result", id: command.id, error: "editor unavailable")))
            return
        }
        setEditDraft(command.prompt)
        reply(encode(StatusResult(kind: "set-edit-draft-result", id: command.id)))
    }

}
#endif
