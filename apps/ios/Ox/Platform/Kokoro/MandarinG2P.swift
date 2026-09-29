import Foundation

nonisolated struct MandarinG2P {
    private struct Syllable {
        let base: String
        var tone: Int
        let source: Character?
        var erhua = false
    }

    private let phrases: [String: [String]]
    private let singles: [UInt32: [String]]
    private let maxPhraseLength: Int
    private let english: EnglishG2P

    init(assets: URL, bundle: KokoroAssets, tokenizer: KokoroTokenizer) throws {
        phrases = try Self.readPhrases(Data(contentsOf: assets.appendingPathComponent("assets/pinyin_phrases.bin")))
        singles = try Self.readSingles(Data(contentsOf: assets.appendingPathComponent("assets/pinyin_single.bin")))
        maxPhraseLength = phrases.keys.map(\.count).max() ?? 1
        english = try EnglishG2P(url: bundle.url("G2P/english.dict"), tokenizer: tokenizer)
        guard !phrases.isEmpty, !singles.isEmpty else { throw KokoroAssetError.invalid("Mandarin dictionaries") }
    }

    func phonemize(_ text: String) throws -> String {
        let characters = Array(Self.normalize(MandarinNumberNormalizer.normalize(text)))
        var output = ""
        var syllables: [Syllable] = []
        var latin = ""

        func flushSyllables() {
            guard !syllables.isEmpty else { return }
            Self.mergeErhua(&syllables)
            Self.applySandhi(&syllables)
            for syllable in syllables {
                if let value = Self.bopomofo(syllable) { output.append(value) }
            }
            syllables.removeAll(keepingCapacity: true)
        }

        func flushLatin() throws {
            guard !latin.isEmpty else { return }
            let text = latin.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                if !output.isEmpty, output.last != " " { output.append(" ") }
                output.append(try english.phonemize(text))
                output.append(" ")
            }
            latin.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if Self.isHanzi(character) {
                try flushLatin()
                let length = min(maxPhraseLength, characters.count - index)
                var match: [String]?
                var matchCharacters: [Character]?
                var matchLength = 0
                if length >= 2 {
                    for count in stride(from: length, through: 2, by: -1) {
                        let candidate = String(characters[index..<(index + count)])
                        if let value = phrases[candidate] {
                            match = value
                            matchCharacters = Array(candidate)
                            matchLength = count
                            break
                        }
                    }
                }
                if let match, let matchCharacters {
                    syllables.append(contentsOf: zip(matchCharacters, match).map {
                        Self.normalizePinyin($0.1, source: $0.0)
                    })
                    index += matchLength
                } else {
                    if let scalar = character.unicodeScalars.first,
                        let value = singles[scalar.value]?.first
                    {
                        syllables.append(Self.normalizePinyin(value, source: character))
                    }
                    index += 1
                }
                continue
            }
            if Self.punctuation.contains(character) {
                try flushLatin()
                flushSyllables()
                output.append(character)
            } else if character.isLetter {
                flushSyllables()
                latin.append(character)
            } else if character == " " {
                flushSyllables()
                latin.append(" ")
            } else {
                try flushLatin()
                flushSyllables()
            }
            index += 1
        }
        try flushLatin()
        flushSyllables()
        let result = output.trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { throw KokoroAssetError.unsupportedText }
        return result
    }

    static func containsHanzi(_ text: String) -> Bool {
        text.contains { isHanzi($0) }
    }

    private static func isHanzi(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
            || (0x30000...0x3134F).contains(value)
            || value == 0x3007
    }

    private static let punctuation = Set(";:,.!?/—…\"()“” ")

    private static func normalize(_ text: String) -> String {
        let mapped: [Character: Character] = [
            "，": ",", "、": ",", "。": ".", "！": "!", "？": "?",
            "；": ";", "：": ":", "（": "(", "）": ")",
        ]
        var result = ""
        for character in text {
            if let replacement = mapped[character] {
                result.append(replacement)
            } else if character.isWhitespace {
                if result.last != " " { result.append(" ") }
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readSingles(_ data: Data) throws -> [UInt32: [String]] {
        var result: [UInt32: [String]] = [:]
        var offset = 0
        while offset < data.count {
            guard offset + 5 <= data.count else { throw KokoroAssetError.invalid("pinyin_single.bin") }
            let scalar = UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
            offset += 4
            let count = Int(data[offset])
            offset += 1
            result[scalar] = try readValues(data, count: count, offset: &offset)
        }
        return result
    }

    private static func readPhrases(_ data: Data) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        var offset = 0
        while offset < data.count {
            guard offset + 2 <= data.count else { throw KokoroAssetError.invalid("pinyin_phrases.bin") }
            let length = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
            guard offset + length + 1 <= data.count,
                let phrase = String(data: data[offset..<(offset + length)], encoding: .utf8)
            else { throw KokoroAssetError.invalid("pinyin_phrases.bin") }
            offset += length
            let count = Int(data[offset])
            offset += 1
            result[phrase] = try readValues(data, count: count, offset: &offset)
        }
        return result
    }

    private static func readValues(_ data: Data, count: Int, offset: inout Int) throws -> [String] {
        var values: [String] = []
        for _ in 0..<count {
            guard offset < data.count else { throw KokoroAssetError.invalid("Mandarin dictionary") }
            let length = Int(data[offset])
            offset += 1
            guard offset + length <= data.count,
                let value = String(data: data[offset..<(offset + length)], encoding: .utf8)
            else { throw KokoroAssetError.invalid("Mandarin dictionary") }
            offset += length
            values.append(value)
        }
        return values
    }

    private static let vowels: [Character: (Character, Int)] = [
        "ā": ("a", 1), "á": ("a", 2), "ǎ": ("a", 3), "à": ("a", 4),
        "ē": ("e", 1), "é": ("e", 2), "ě": ("e", 3), "è": ("e", 4),
        "ī": ("i", 1), "í": ("i", 2), "ǐ": ("i", 3), "ì": ("i", 4),
        "ō": ("o", 1), "ó": ("o", 2), "ǒ": ("o", 3), "ò": ("o", 4),
        "ū": ("u", 1), "ú": ("u", 2), "ǔ": ("u", 3), "ù": ("u", 4),
        "ǖ": ("v", 1), "ǘ": ("v", 2), "ǚ": ("v", 3), "ǜ": ("v", 4),
        "ü": ("v", 0), "ń": ("n", 2), "ň": ("n", 3), "ǹ": ("n", 4),
    ]

    private static func normalizePinyin(_ value: String, source: Character?) -> Syllable {
        var base = ""
        var tone = 5
        for character in value {
            if let mapped = vowels[character] {
                base.append(mapped.0)
                if mapped.1 > 0 { tone = mapped.1 }
            } else {
                base.append(character)
            }
        }
        return Syllable(base: base, tone: tone, source: source)
    }

    private static func applySandhi(_ values: inout [Syllable]) {
        guard values.count > 1 else { return }
        for index in 0..<(values.count - 1) {
            let next = values[index + 1].tone
            if values[index].base == "bu", values[index].tone == 4, next == 4 {
                values[index].tone = 2
            } else if values[index].base == "yi", values[index].tone == 1 {
                if next == 4 { values[index].tone = 2 }
                else if (1...3).contains(next) { values[index].tone = 4 }
            }
        }
        var index = 0
        while index < values.count {
            guard values[index].tone == 3 else {
                index += 1
                continue
            }
            var end = index
            while end < values.count && values[end].tone == 3 { end += 1 }
            if end - index >= 2 {
                for position in index..<(end - 1) {
                    values[position].tone = 2
                }
            }
            index = end
        }
    }

    private static func mergeErhua(_ values: inout [Syllable]) {
        guard values.count >= 2 else { return }
        var index = values.count - 1
        while index >= 1 {
            if values[index].source == "儿", values[index - 1].base != "er", !values[index - 1].base.isEmpty {
                values[index - 1].erhua = true
                values.remove(at: index)
                index -= 2
            } else {
                index -= 1
            }
        }
    }

    private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s"]
    private static let initialMap = [
        "b": "ㄅ", "p": "ㄆ", "m": "ㄇ", "f": "ㄈ", "d": "ㄉ", "t": "ㄊ", "n": "ㄋ", "l": "ㄌ",
        "g": "ㄍ", "k": "ㄎ", "h": "ㄏ", "j": "ㄐ", "q": "ㄑ", "x": "ㄒ", "zh": "ㄓ", "ch": "ㄔ",
        "sh": "ㄕ", "r": "ㄖ", "z": "ㄗ", "c": "ㄘ", "s": "ㄙ",
    ]
    private static let finalMap = [
        "a": "ㄚ", "o": "ㄛ", "e": "ㄜ", "ie": "ㄝ", "ai": "ㄞ", "ei": "ㄟ", "ao": "ㄠ", "ou": "ㄡ",
        "an": "ㄢ", "en": "ㄣ", "ang": "ㄤ", "eng": "ㄥ", "er": "ㄦ", "i": "ㄧ", "u": "ㄨ", "v": "ㄩ",
        "ii": "ㄭ", "iii": "十", "ve": "月", "ia": "压", "ian": "言", "iang": "阳", "iao": "要",
        "in": "阴", "ing": "应", "iong": "用", "iou": "又", "ong": "中", "ua": "穵", "uai": "外",
        "uan": "万", "uang": "王", "uei": "为", "uen": "文", "ueng": "瓮", "uo": "我", "van": "元", "vn": "云",
    ]
    private static let zeroInitial = [
        "yi": "i", "ya": "ia", "ye": "ie", "yao": "iao", "you": "iou", "yan": "ian", "yin": "in",
        "yang": "iang", "ying": "ing", "yong": "iong", "wu": "u", "wa": "ua", "wo": "uo",
        "wai": "uai", "wei": "uei", "wan": "uan", "wen": "uen", "wang": "uang", "weng": "ueng",
        "yu": "v", "yue": "ve", "yuan": "van", "yun": "vn",
    ]

    private static func bopomofo(_ syllable: Syllable) -> String? {
        let value = zeroInitial[syllable.base] ?? syllable.base
        let initial = initials.first { value.hasPrefix($0) } ?? ""
        var final = String(value.dropFirst(initial.count))
        if final == "i" {
            if ["z", "c", "s"].contains(initial) { final = "ii" }
            if ["zh", "ch", "sh", "r"].contains(initial) { final = "iii" }
        }
        if ["j", "q", "x"].contains(initial), final.hasPrefix("u") {
            final = "v" + final.dropFirst()
        }
        if !initial.isEmpty {
            switch final {
            case "ui": final = "uei"
            case "un": final = "uen"
            case "iu": final = "iou"
            default: break
            }
        }
        guard let ending = finalMap[final] else { return nil }
        let suffix = syllable.erhua ? "ㄦ" : ""
        return (initialMap[initial] ?? "") + ending + suffix + String(syllable.tone)
    }
}
