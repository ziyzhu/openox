import Foundation

nonisolated enum BuiltInGuidance {
    struct Entry: Sendable {
        let path: String
        let size: Int?
        var isDirectory: Bool { size == nil }
    }

    static let names = ["evolve", "import-memory", "manage-providers", "manage-skills", "visualize"]

    private static let contents: Result<[String: String], any Error> = Result {
        do {
            guard let root = Bundle.main.url(forResource: "ModelGuidance", withExtension: "bundle"),
                  let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                throw RuntimeError.bridge("Built-in Ox guidance is unavailable")
            }
            var files: [String: String] = [:]
            var total = 0
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true else { throw RuntimeError.bridge("Built-in guidance cannot contain symbolic links") }
                guard values.isRegularFile == true else { continue }
                let path = String(url.path.dropFirst(root.path.count + 1))
                total += values.fileSize ?? 0
                guard validPath(path), files.count < 64, total <= 512 * 1024,
                      (values.fileSize ?? 0) <= VirtualFileSystem.maximumReadBytes else { throw RuntimeError.bridge("Built-in guidance has invalid paths or exceeds resource limits") }
                files[path] = try String(contentsOf: url, encoding: .utf8)
            }
            for name in names {
                guard files["\(name)/guide.md"]?.isEmpty == false else { throw RuntimeError.bridge("Missing built-in guidance: \(name)") }
            }
            return files
        } catch {
            Log.app.error("BuiltInGuidance.load error=\(error.localizedDescription)")
            throw error
        }
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            $0.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil
        }
    }

    static func text(_ path: String) throws -> String {
        guard validPath(path), let text = try contents.get()[path] else {
            throw VirtualFileSystem.Error.notFile("guidance/\(path)")
        }
        return text
    }

    static func isDirectory(_ path: String) throws -> Bool {
        let files = try contents.get()
        return path.isEmpty || files.keys.contains { $0.hasPrefix(path + "/") }
    }

    static func paths(under path: String = "") throws -> [String] {
        let files = try contents.get()
        guard path.isEmpty || files[path] != nil || files.keys.contains(where: { $0.hasPrefix(path + "/") }) else {
            throw VirtualFileSystem.Error.invalidPath("guidance/\(path)")
        }
        return files.keys.filter { path.isEmpty || $0 == path || $0.hasPrefix(path + "/") }.sorted()
    }

    static func entries(under path: String) throws -> [Entry] {
        guard try isDirectory(path) else { throw VirtualFileSystem.Error.notDirectory("guidance/\(path)") }
        let prefix = path.isEmpty ? "" : path + "/"
        let children = Set(try paths(under: path).map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
        let files = try contents.get()
        return children.sorted().map {
            let relative = prefix + $0
            return Entry(path: "guidance/" + relative, size: files[relative]?.utf8.count)
        }
    }
}
