import Foundation

nonisolated struct KokoroSegmenter {
    let g2p: EnglishG2P
    let tokenizer: KokoroTokenizer

    func split(_ text: String, speed: Float) throws -> [String] {
        let trimmed = KokoroTextNormalizer().normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let budget = min(110, max(24, Int(90 * min(speed, 1))))
        var result: [String] = []
        for sentence in sentenceParts(trimmed) {
            try append(sentence, budget: budget, to: &result)
        }
        return result
    }

    func halve(_ text: String) -> (String, String)? {
        let characters = Array(text)
        let midpoint = characters.count / 2
        guard characters.count > 1 else { return nil }
        let priority = [";:", ",", " "]
        for delimiters in priority {
            let positions = characters.indices.filter {
                $0 > 0 && $0 < characters.count - 1 && delimiters.contains(characters[$0])
            }
            if let position = positions.min(by: { abs($0 - midpoint) < abs($1 - midpoint) }) {
                let left = String(characters[...position]).trimmingCharacters(in: .whitespaces)
                let right = String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces)
                if !left.isEmpty && !right.isEmpty { return (left, right) }
            }
        }
        return nil
    }

    private func sentenceParts(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { parts.append(part) }
                current = ""
            }
        }
        let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !part.isEmpty { parts.append(part) }
        return parts
    }

    private func append(_ text: String, budget: Int, to output: inout [String]) throws {
        let phonemes = try g2p.phonemize(text)
        if tokenizer.tokenCount(phonemes) <= budget {
            output.append(text)
            return
        }
        let characters = Array(text)
        for delimiters in [";:", ",", " "] {
            let positions = characters.indices.reversed().filter {
                $0 > 0 && $0 < characters.count - 1 && delimiters.contains(characters[$0])
            }
            for position in positions {
                let left = String(characters[...position]).trimmingCharacters(in: .whitespaces)
                let right = String(characters[(position + 1)...]).trimmingCharacters(in: .whitespaces)
                guard !left.isEmpty, !right.isEmpty else { continue }
                if tokenizer.tokenCount(try g2p.phonemize(left)) <= budget {
                    try append(left, budget: budget, to: &output)
                    try append(right, budget: budget, to: &output)
                    return
                }
            }
        }
        throw KokoroAssetError.chunkTooLong
    }
}
