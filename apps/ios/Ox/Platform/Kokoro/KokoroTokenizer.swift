import Foundation

nonisolated struct KokoroTokenizer {
    private let ids: [Unicode.Scalar: Int32]

    init(jsonURL: URL) throws {
        let values = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: jsonURL))
        var ids: [Unicode.Scalar: Int32] = [:]
        for (key, value) in values {
            guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else {
                throw KokoroAssetError.invalid("Mandarin vocabulary")
            }
            ids[scalar] = value
        }
        guard ids[" "] != nil, ids["ㄅ"] != nil else {
            throw KokoroAssetError.invalid("Mandarin vocabulary")
        }
        self.ids = ids
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 12, data.prefix(8) == Data("KOVOCAB1".utf8) else {
            throw KokoroAssetError.invalid("kokoro-vocab.bin")
        }
        let count = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) })
        guard count > 0, data.count == 12 + count * 8 else {
            throw KokoroAssetError.invalid("kokoro-vocab.bin")
        }
        var ids: [Unicode.Scalar: Int32] = [:]
        data.withUnsafeBytes { bytes in
            for index in 0..<count {
                let codepoint = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12 + index * 8, as: UInt32.self))
                let identifier = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + index * 8, as: UInt32.self))
                if let scalar = Unicode.Scalar(codepoint) {
                    ids[scalar] = Int32(identifier)
                }
            }
        }
        guard ids[" "] == 16 else { throw KokoroAssetError.invalid("kokoro-vocab.bin") }
        self.ids = ids
    }

    func encode(_ phonemes: String) throws -> [Int32] {
        let encoded = phonemes.unicodeScalars.compactMap { ids[$0] }
        guard !encoded.isEmpty else { throw KokoroAssetError.unsupportedText }
        return [0] + encoded + [0]
    }

    func tokenCount(_ phonemes: String) -> Int {
        phonemes.unicodeScalars.reduce(0) { $0 + (ids[$1] == nil ? 0 : 1) }
    }

    func supports(_ scalar: Unicode.Scalar) -> Bool {
        ids[scalar] != nil
    }
}
