import Foundation

nonisolated enum JavaScriptOutputLimits {
    static let maxOutputTokens = 10_000
    static let charactersPerToken = 4

    static func tokens(characters: Int) -> Int {
        (characters + charactersPerToken - 1) / charactersPerToken
    }

    static func excerpt(_ text: String) -> (head: Substring, tail: Substring)? {
        let budget = maxOutputTokens * charactersPerToken
        let characters = text.utf16
        guard characters.count > budget else { return nil }
        let headEnd = characters.index(characters.startIndex, offsetBy: budget / 2)
        let tailStart = characters.index(characters.endIndex, offsetBy: -(budget - budget / 2))
        return (text[..<headEnd], text[tailStart...])
    }
}

actor JavaScriptOutputStore {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ox-output-\(UUID().uuidString)")
    private var saved: [(name: String, bytes: Int)] = []

    deinit {
        let directory = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func save(_ text: String) throws -> String {
        let data = Data(text.utf8)
        guard data.count <= FileLimits.fileBytes else {
            throw RuntimeError.bridge(ModelGuidance.text("output.cacheExceeded"))
        }
        while saved.reduce(0, { $0 + $1.bytes }) + data.count > FileLimits.fileBytes, !saved.isEmpty {
            let oldest = saved.removeFirst()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(oldest.name))
            Log.session.info("output.evict name=\(oldest.name) bytes=\(oldest.bytes) incomingBytes=\(data.count)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString + ".txt"
        try data.write(to: directory.appendingPathComponent(id), options: .atomic)
        saved.append((id, data.count))
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
        if let name, let url, !FileManager.default.fileExists(atPath: url.path) {
            Log.session.info("output.expired name=\(name) operation=\(operation)")
            throw RuntimeError.bridge(ModelGuidance.text("output.expired"))
        }
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
