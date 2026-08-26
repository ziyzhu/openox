import Foundation

nonisolated enum JavaScriptOutputLimits {
    static let maxBytes = 50 * 1024
    static let maxLines = 2_000

    static func preview(_ text: String) -> String {
        let bytes = text.utf8
        if bytes.count <= maxBytes {
            let lines = bytes.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } + (bytes.last == 10 ? 0 : 1)
            if lines <= maxLines { return text }
        }
        let end = bytes.last == 10 ? bytes.index(before: bytes.endIndex) : bytes.endIndex
        var start = end
        var keptStart = end
        for line in 0..<maxLines {
            let lineStart = bytes[..<start].lastIndex(of: 10).map { bytes.index(after: $0) } ?? bytes.startIndex
            guard bytes.distance(from: lineStart, to: end) <= maxBytes else {
                if line == 0 {
                    keptStart = bytes.index(end, offsetBy: -maxBytes)
                    while bytes[keptStart] & 0xc0 == 0x80 { keptStart = bytes.index(after: keptStart) }
                }
                break
            }
            keptStart = lineStart
            guard lineStart > bytes.startIndex else { break }
            start = bytes.index(before: lineStart)
        }
        return String(decoding: bytes[keptStart..<end], as: UTF8.self)
    }
}

final class JavaScriptOutputStore {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ox-output-\(UUID().uuidString)")
    private var storedBytes = 0

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func save(_ text: String) throws -> String {
        let data = Data(text.utf8)
        guard storedBytes + data.count <= ArtifactLimits.fileBytes else {
            throw RuntimeError.bridge("JavaScript output cache exceeds 32 MiB. Filter results before printing and rerun the source.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try data.write(to: directory.appendingPathComponent(id), options: .atomic)
        storedBytes += data.count
        return id
    }

    func read(_ id: String) throws -> String {
        guard let uuid = UUID(uuidString: id) else { throw RuntimeError.bridge("Invalid output reference.") }
        let url = directory.appendingPathComponent(uuid.uuidString)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeError.bridge("Output reference is unavailable in this chat. Rerun the original source and print the needed portion.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

extension Chat {
    public func readJavaScriptOutput(id: String, purpose: String) async throws -> JSONValue? {
        try await tracked(.outputRead, .object(["id": .string(id)]), purpose: purpose) {
            .string(try javaScriptOutputs.read(id))
        }
    }
}
