import Foundation

nonisolated struct KokoroTextNormalizer {
    private let numberPattern = try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#)

    static func supportsEnglish(_ text: String) -> Bool {
        var hasSpeakableText = false
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                guard scalar.value <= 0x024F || (0x1E00...0x1EFF).contains(scalar.value) else {
                    return false
                }
                hasSpeakableText = true
            } else if (0x30...0x39).contains(scalar.value) {
                hasSpeakableText = true
            }
        }
        return hasSpeakableText
    }

    func normalize(_ text: String) -> String {
        let text = text
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = numberPattern.matches(in: text, range: range)
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        var result = text
        for match in matches.reversed() {
            guard let source = Range(match.range, in: result) else { continue }
            let raw = String(result[source])
            let spoken: String
            if let point = raw.firstIndex(of: ".") {
                let integer = String(raw[..<point])
                let fraction = raw[raw.index(after: point)...]
                let head = Int(integer).flatMap { formatter.string(from: NSNumber(value: $0)) } ?? integer
                let tail = fraction.map { digit in
                    Int(String(digit)).flatMap { formatter.string(from: NSNumber(value: $0)) } ?? String(digit)
                }.joined(separator: " ")
                spoken = "\(head) point \(tail)"
            } else if let number = Int(raw), let words = formatter.string(from: NSNumber(value: number)) {
                spoken = words
            } else {
                spoken = raw
            }
            result.replaceSubrange(source, with: spoken)
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
