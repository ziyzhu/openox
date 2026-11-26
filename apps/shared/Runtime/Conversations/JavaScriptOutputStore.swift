import Foundation

nonisolated enum JavaScriptOutputLimits {
    static let maxBytes = 50 * 1024
    static let maxLines = 2_000

    static func preview(_ text: String, maxLines: Int = maxLines, maxBytes: Int = maxBytes) -> String {
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

actor JavaScriptOutputStore {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ox-output-\(UUID().uuidString)")
    private var storedBytes = 0

    deinit {
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func save(_ text: String) throws -> String {
        let data = Data(text.utf8)
        guard storedBytes + data.count <= FileLimits.fileBytes else {
            throw RuntimeError.bridge(ModelGuidance.text("output.cacheExceeded"))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString + ".txt"
        try data.write(to: directory.appendingPathComponent(id), options: .atomic)
        storedBytes += data.count
        return "/tmp/" + id
    }

    func operation(_ operation: String, path: String) throws -> JSONValue {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "tmp", parts.count <= 2 else { throw VirtualFileSystem.Error.invalidPath(path) }
        let name = parts.count == 2 ? parts[1] : nil
        if let name {
            guard name.hasSuffix(".txt"), UUID(uuidString: String(name.dropLast(4))) != nil else {
                throw VirtualFileSystem.Error.invalidPath(path)
            }
        }
        let url = name.map { directory.appendingPathComponent($0) }
        func info(_ name: String, size: Int) -> JSONValue {
            .object(["path": .string("tmp/" + name), "name": .string(name), "kind": .string("file"),
                     "size": .int(size), "mtimeMs": .int(0)])
        }
        switch operation {
        case "info":
            guard let name, let url else {
                return .object(["path": .string("tmp"), "name": .string("tmp"), "kind": .string("directory"),
                                "size": .int(0), "mtimeMs": .int(0)])
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return info(name, size: size)
        case "list":
            guard name == nil else { throw VirtualFileSystem.Error.notDirectory(path) }
            guard FileManager.default.fileExists(atPath: directory.path) else { return .array([]) }
            return .array(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().map {
                info($0, size: try directory.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            })
        case "read":
            guard let url else { throw VirtualFileSystem.Error.notFile(path) }
            return .object(["text": .string(try String(contentsOf: url, encoding: .utf8)), "truncated": .bool(false), "unsupported": .null])
        default:
            throw VirtualFileSystem.Error.unsupportedMutation(path)
        }
    }
}
