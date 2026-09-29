
import Foundation

nonisolated struct EnglishPhonemizer {

    let wordToPhonemes: [String: String]
    let caseSensitiveWordToPhonemes: [String: String]
    var customLexicon: [String: String] = [:]
    let allowedPunctuation: Set<Character>

    func phonemize(_ text: String, fallback: (String) throws -> [String]?) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KokoroG2PError("empty input") }

        let prepared = Self.normalizeApostrophes(trimmed)

        var parts: [String] = []
        for token in Self.splitWords(prepared) {
            if token.isEmpty { continue }

            if token.count == 1, let ch = token.first, !ch.isLetter, !ch.isNumber {
                guard allowedPunctuation.contains(ch) else { continue }
                if parts.isEmpty {
                    parts.append(String(ch))
                } else {
                    parts[parts.count - 1].append(ch)
                }
                continue
            }

            if let ipa = try resolveWord(token, fallback: fallback) {
                parts.append(ipa)
            }
        }

        let joined = parts.joined(separator: " ")
        if joined.isEmpty { throw KokoroG2PError("produced no phonemes for input '\(trimmed)'") }
        return joined
    }


    private func resolveWord(
        _ word: String,
        allowFallback: Bool = true,
        fallback: (String) throws -> [String]?
    ) throws -> String? {
        let normalized = Self.normalizeKey(word)
        let lowered = word.lowercased()

        if let custom = customLexicon[word] ?? customLexicon[normalized] {
            return custom
        }

        if Self.letterNameOverrides.contains(word) {
            if let spelled = spellAsLetterNames(word) {
                return spelled
            }
            Log.ui.warning("Kokoro.G2P letter override used dictionary pronunciation")
        }

        if let phonemes = lookupMisakiWord(word) {
            return phonemes
        }

        if Self.isInitialismCandidate(word), let spelled = spellAsLetterNames(word) {
            return spelled
        }

        if let possessive = resolveWholeCompoundPossessive(word, lowered: lowered) {
            return possessive
        }

        if word.contains("-"),
            let compound = try resolveHyphenatedCompound(word, allowFallback: allowFallback, fallback: fallback)
        {
            return compound
        }

        if let possessive = try resolvePossessive(word, lowered: lowered, fallback: fallback) {
            return possessive
        }

        guard allowFallback, !normalized.isEmpty else { return nil }
        if let phonemes = try fallback(normalized), !phonemes.isEmpty {
            return phonemes.joined()
        }
        Log.ui.warning("Kokoro.G2P found no pronunciation for a word")
        return nil
    }

    private func lookupMisakiWord(_ word: String) -> String? {
        let normalized = Self.normalizeKey(word)
        guard
            let phonemes = caseSensitiveWordToPhonemes[word]
                ?? caseSensitiveWordToPhonemes[normalized]
                ?? wordToPhonemes[word.lowercased()]
                ?? wordToPhonemes[normalized],
            !phonemes.isEmpty
        else {
            return nil
        }
        return phonemes
    }

    private func resolveWholeCompoundPossessive(_ word: String, lowered: String) -> String? {
        guard word.contains("-"), lowered.hasSuffix("'s") else { return nil }
        let stem = String(word.dropLast(2))
        guard !stem.isEmpty, !stem.hasSuffix("'") else { return nil }
        guard
            let stemIPA = customLexicon[stem]
                ?? customLexicon[Self.normalizeKey(stem)]
                ?? lookupMisakiWord(stem),
            !stemIPA.isEmpty
        else {
            return nil
        }
        return stemIPA + Self.clitic(after: stemIPA)
    }

    private func resolveHyphenatedCompound(
        _ word: String,
        allowFallback: Bool,
        fallback: (String) throws -> [String]?
    ) throws -> String? {
        let parts = word.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }

        var resolved: [String] = []
        for part in parts {
            guard let ipa = try resolveWord(part, allowFallback: allowFallback, fallback: fallback),
                !ipa.isEmpty
            else {
                return nil
            }
            resolved.append(ipa)
        }
        return resolved.joined(separator: " ")
    }


    private func resolvePossessive(
        _ word: String,
        lowered: String,
        fallback: (String) throws -> [String]?
    ) throws -> String? {
        guard lowered.count >= 3, lowered.hasSuffix("'s") else { return nil }
        let stem = String(word.dropLast(2))
        guard !stem.isEmpty, !stem.hasSuffix("'") else { return nil }
        guard let stemIPA = try resolveWord(stem, allowFallback: false, fallback: fallback), !stemIPA.isEmpty
        else {
            return nil
        }
        return stemIPA + Self.clitic(after: stemIPA)
    }

    private static let voicelessNonSibilants: Set<Character> = ["p", "t", "k", "f", "θ"]
    private static let sibilants: Set<Character> = ["s", "z", "ʃ", "ʒ", "ʧ", "ʤ"]

    static func clitic(after stemIPA: String) -> String {
        guard let last = stemIPA.last else { return "z" }
        if voicelessNonSibilants.contains(last) { return "s" }
        if sibilants.contains(last) { return "ᵻz" }
        return "z"
    }


    private static let letterNameOverrides: Set<String> = ["AI", "US"]

    private static func isInitialismCandidate(_ word: String) -> Bool {
        guard (2...5).contains(word.count) else { return false }
        return word.allSatisfy { $0.isASCII && $0.isUppercase && $0.isLetter }
    }

    private func spellAsLetterNames(_ word: String) -> String? {
        var letters: [String] = []
        for character in word {
            guard let tokens = caseSensitiveWordToPhonemes[String(character)], !tokens.isEmpty else {
                return nil
            }
            letters.append(tokens)
        }
        return letters.isEmpty ? nil : letters.joined(separator: " ")
    }


    private static let smartApostrophes: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    static func normalizeApostrophes(_ text: String) -> String {
        guard text.contains(where: { smartApostrophes.contains($0) }) else { return text }
        return String(text.map { smartApostrophes.contains($0) ? "'" : $0 })
    }

    static func normalizeKey(_ word: String) -> String {
        let allowedSet = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'"))
        let filtered = word.lowercased().unicodeScalars.filter { allowedSet.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    private static let knownLeadingApostropheWords: Set<String> = [
        "'cause", "'em", "'til", "'tis", "'twas", "'twere",
    ]

    static func splitWords(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""

        func flushCurrent() {
            if !current.isEmpty {
                out.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for index in text.indices {
            let ch = text[index]
            if ch.isWhitespace {
                flushCurrent()
            } else if ch == "'" {
                let nextIndex = text.index(after: index)
                let nextIsWord =
                    nextIndex < text.endIndex && (text[nextIndex].isLetter || text[nextIndex].isNumber)
                if !current.isEmpty && nextIsWord {
                    current.append(ch)
                } else if current.isEmpty && startsKnownLeadingApostropheWord(in: text, at: index) {
                    current.append(ch)
                } else {
                    flushCurrent()
                    out.append(String(ch))
                }
            } else if ch.isLetter || ch.isNumber || ch == "-" {
                current.append(ch)
            } else {
                flushCurrent()
                out.append(String(ch))
            }
        }
        flushCurrent()
        return out
    }

    private static func startsKnownLeadingApostropheWord(in text: String, at apostropheIndex: String.Index) -> Bool {
        let nextIndex = text.index(after: apostropheIndex)
        guard nextIndex < text.endIndex, text[nextIndex].isLetter else { return false }
        var endIndex = nextIndex
        while endIndex < text.endIndex, text[endIndex].isLetter {
            endIndex = text.index(after: endIndex)
        }
        return knownLeadingApostropheWords.contains("'" + text[nextIndex..<endIndex].lowercased())
    }
}
