import Foundation

nonisolated enum ExactTextReplacement {
    static func count(_ find: String, in text: String) -> Int {
        guard !find.isEmpty else { return 0 }
        var count = 0
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: find, range: start..<text.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    static func replace(_ find: String, with replacement: String, in text: String) -> String {
        guard let range = text.range(of: find) else { return text }
        var result = text
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
