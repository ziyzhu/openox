import Foundation

nonisolated struct KokoroG2PError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

nonisolated struct EnglishG2P {
    private let phonemizer: EnglishPhonemizer
    private let normalizer = KokoroTextNormalizer()

    init(url: URL, tokenizer: KokoroTokenizer) throws {
        let data = try String(contentsOf: url, encoding: .utf8)
        var lower: [String: String] = [:]
        var caseSensitive: [String: String] = [:]
        for line in data.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw KokoroAssetError.invalid("english.dict") }
            let pronunciation = String(fields[2].unicodeScalars.filter { tokenizer.supports($0) })
            if fields[0] == "l" {
                lower[String(fields[1])] = pronunciation
            } else if fields[0] == "c" {
                caseSensitive[String(fields[1])] = pronunciation
            } else {
                throw KokoroAssetError.invalid("english.dict")
            }
        }
        guard !lower.isEmpty else { throw KokoroAssetError.invalid("english.dict") }
        let punctuation = Set(";:,.!?—…\"()“”".map { $0 })
        phonemizer = EnglishPhonemizer(
            wordToPhonemes: lower,
            caseSensitiveWordToPhonemes: caseSensitive,
            allowedPunctuation: punctuation
        )
    }

    func phonemize(_ text: String) throws -> String {
        guard KokoroTextNormalizer.supportsEnglish(text) else {
            throw KokoroAssetError.unsupportedText
        }
        return try phonemizer.phonemize(normalizer.normalize(text)) { word in
            let letters = word.uppercased().filter(\.isLetter)
            let spelled = letters.compactMap { phonemizer.caseSensitiveWordToPhonemes[String($0)] }
            guard spelled.count == letters.count, !spelled.isEmpty else {
                throw KokoroAssetError.unsupportedText
            }
            return spelled
        }
    }
}
