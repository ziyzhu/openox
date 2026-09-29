import Foundation

nonisolated enum KokoroAssetError: LocalizedError {
    case missing(String)
    case invalid(String)
    case notInstalled
    case unsupportedText
    case chunkTooLong
    case silentAudio

    var errorDescription: String? {
        switch self {
        case .missing(let name): "Missing Kokoro asset: \(name)"
        case .invalid(let name): "Invalid Kokoro asset: \(name)"
        case .notInstalled: "Install the offline voice in Settings → Voice to read messages aloud."
        case .unsupportedText: "The text has no supported pronunciation."
        case .chunkTooLong: "The text could not fit within the Kokoro model."
        case .silentAudio: "The voice model generated silent audio."
        }
    }
}

nonisolated struct KokoroAssets {
    let root: URL

    init(bundle: Bundle = .main) throws {
        guard let root = bundle.url(forResource: "Kokoro", withExtension: "bundle") else {
            throw KokoroAssetError.missing("Kokoro.bundle")
        }
        self.root = root
    }

    func url(_ path: String) throws -> URL {
        let result = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: result.path) else {
            throw KokoroAssetError.missing(path)
        }
        return result
    }
}

nonisolated struct KokoroVoice {
    private let data: Data
    let rowCount: Int
    private let payloadOffset: Int

    init(rawURL: URL) throws {
        let data = try Data(contentsOf: rawURL, options: .mappedIfSafe)
        guard data.count == 510 * 256 * 4 else {
            throw KokoroAssetError.invalid(rawURL.lastPathComponent)
        }
        self.data = data
        rowCount = 510
        payloadOffset = 0
    }

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 16, data.prefix(4) == Data("KOVC".utf8) else {
            throw KokoroAssetError.invalid("af_heart.bin")
        }
        let version = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let rows = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) })
        let width = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
        guard version == 1, rows > 0, width == 256, data.count == 16 + rows * width * 4 else {
            throw KokoroAssetError.invalid("af_heart.bin")
        }
        self.data = data
        rowCount = rows
        payloadOffset = 16
    }

    func embedding(forTokenCount count: Int) -> [Float] {
        let row = min(max(count - 1, 0), rowCount - 1)
        return data.withUnsafeBytes { bytes in
            (0..<256).map { column in
                let bits = bytes.loadUnaligned(fromByteOffset: payloadOffset + (row * 256 + column) * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
    }
}

nonisolated struct KokoroHarmonicWeights {
    let weights: [Float]
    let bias: Float

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 16, data.prefix(8) == Data("KOHARM01".utf8) else {
            throw KokoroAssetError.invalid("harmonic-weights.bin")
        }
        let count = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) })
        guard count == 9, data.count == 16 + count * 4 else {
            throw KokoroAssetError.invalid("harmonic-weights.bin")
        }
        let floats = data.withUnsafeBytes { bytes in
            (0...count).map { index in
                let bits = bytes.loadUnaligned(fromByteOffset: 12 + index * 4, as: UInt32.self)
                return Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        weights = Array(floats.dropLast())
        bias = floats[count]
    }
}
