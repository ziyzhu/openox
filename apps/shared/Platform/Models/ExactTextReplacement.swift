import Foundation

nonisolated enum ExactTextReplacement {
    struct Edit: Sendable {
        let oldText: String
        let newText: String
    }

    struct Applied: Equatable, Sendable {
        let text: String
        let firstChangedLine: Int
    }

    enum Failure: LocalizedError, Equatable, Sendable {
        case emptyEdits
        case appendAmbiguous
        case missing(index: Int)
        case ambiguous(index: Int, matches: Int)
        case overlapping(Int, Int)
        case unchanged

        var errorDescription: String? {
            switch self {
            case .emptyEdits: "At least one edit is required."
            case .appendAmbiguous: "At most one append edit (empty oldText) is allowed, and it cannot be combined with replacements."
            case .missing(let index): "edits[\(index)].oldText was not found. It must match the original file exactly, including whitespace and newlines; read the file again before retrying."
            case .ambiguous(let index, let matches): "edits[\(index)].oldText matched \(matches) locations. Include more surrounding text so it matches exactly once."
            case .overlapping(let first, let second): "edits[\(first)] and edits[\(second)] overlap. Merge them into one edit or target disjoint text."
            case .unchanged: "The edits produced identical content; nothing was changed."
            }
        }
    }

    static func count(_ find: String, in text: String) -> Int {
        ranges(of: find, in: text).count
    }

    static func replace(_ find: String, with replacement: String, in text: String) -> String {
        guard let range = text.range(of: find) else { return text }
        var result = text
        result.replaceSubrange(range, with: replacement)
        return result
    }

    static func apply(_ edits: [Edit], to original: String) throws -> Applied {
        let lineEnding = lineEnding(of: original)
        let base = normalizedLineEndings(original)
        let normalizedEdits = edits.map { Edit(oldText: normalizedLineEndings($0.oldText), newText: normalizedLineEndings($0.newText)) }
        let applied = try applyNormalized(normalizedEdits, to: base)
        guard applied.text != base else { throw Failure.unchanged }
        let text = lineEnding == "\n" ? applied.text : applied.text.replacingOccurrences(of: "\n", with: lineEnding)
        return Applied(text: text, firstChangedLine: applied.firstChangedLine)
    }

    private static func applyNormalized(_ edits: [Edit], to base: String) throws -> Applied {
        guard !edits.isEmpty else { throw Failure.emptyEdits }
        let appends = edits.filter { $0.oldText.isEmpty }
        guard appends.isEmpty || edits.count == 1 else { throw Failure.appendAmbiguous }
        if let append = appends.first {
            return Applied(text: base + append.newText, firstChangedLine: line(at: base.endIndex, in: base))
        }

        let resolved = try edits.enumerated().map { index, edit in
            let matches = ranges(of: edit.oldText, in: base)
            guard let range = matches.first else { throw Failure.missing(index: index) }
            guard matches.count == 1 else { throw Failure.ambiguous(index: index, matches: matches.count) }
            return (index: index, range: range, newText: edit.newText)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        for (previous, current) in zip(resolved, resolved.dropFirst()) where previous.range.upperBound > current.range.lowerBound {
            throw Failure.overlapping(previous.index, current.index)
        }
        var text = base
        for edit in resolved.reversed() {
            text.replaceSubrange(edit.range, with: edit.newText)
        }
        return Applied(text: text, firstChangedLine: line(at: resolved[0].range.lowerBound, in: base))
    }

    private static func lineEnding(of text: String) -> String {
        text.first(where: \.isNewline) == "\r\n" ? "\r\n" : "\n"
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func line(at index: String.Index, in text: String) -> Int {
        text[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let match = text.range(of: needle, range: start..<text.endIndex) {
            matches.append(match)
            start = match.upperBound
        }
        return matches
    }
}
