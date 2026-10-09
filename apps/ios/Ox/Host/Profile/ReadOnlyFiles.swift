import Foundation

nonisolated struct ReadOnlyFiles: Sendable {
    struct Snapshot: Decodable {
        struct Mount: Decodable {
            let path: String
            let access: String
            let files: [String: String]
        }
        let scope: String
        let mounts: [Mount]
    }

    struct Entry: Sendable {
        let path: String
        let size: Int?
        var isDirectory: Bool { size == nil }
    }

    let scope: String
    private let mounts: [String]
    private let contents: [String: String]

    init(snapshot: Snapshot, scope: String, reservedPaths: [String]) throws {
        guard snapshot.scope == scope, !scope.isEmpty, snapshot.mounts.count <= 64 else {
            throw RuntimeError.bridge("Read-only mounts do not belong to the runtime scope or exceed limits")
        }
        var files: [String: String] = [:]
        var paths: [String] = []
        for mount in snapshot.mounts {
            guard mount.access == "readOnly", Self.validPath(mount.path),
                  !reservedPaths.contains(where: { Self.overlaps($0, mount.path) }),
                  !paths.contains(where: { Self.overlaps($0, mount.path) }) else {
                throw RuntimeError.bridge("Invalid or overlapping read-only mount: \(mount.path)")
            }
            paths.append(mount.path)
            for (path, text) in mount.files {
                guard Self.validPath(path), text.utf8.count <= VirtualFileSystem.maximumReadBytes else {
                    throw RuntimeError.bridge("Invalid or oversized read-only file: \(path)")
                }
                files[mount.path + "/" + path] = text
            }
        }
        guard files.count <= 64, files.values.reduce(0, { $0 + $1.utf8.count }) <= 512 * 1024,
              !files.keys.contains(where: { path in files.keys.contains(where: { $0.hasPrefix(path + "/") }) }) else {
            throw RuntimeError.bridge("Read-only files contain conflicting paths or exceed limits")
        }
        self.scope = scope
        mounts = paths.sorted()
        contents = files
        Log.agent.info("ReadOnlyFiles.mount scope=\(scope) mounts=\(mounts.count) files=\(files.count)")
    }

    private static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            $0.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil
        }
    }

    func owns(_ path: String) -> Bool {
        Self.validPath(path) && mounts.contains { Self.overlaps($0, path) }
    }

    func text(_ path: String) throws -> String {
        guard Self.validPath(path), let text = contents[path] else { throw VirtualFileSystem.Error.notFile(path) }
        return text
    }

    func isDirectory(_ path: String) -> Bool {
        path.isEmpty || mounts.contains(path) || mounts.contains { $0.hasPrefix(path + "/") } || contents.keys.contains { $0.hasPrefix(path + "/") }
    }

    func paths(under path: String = "") throws -> [String] {
        guard path.isEmpty || contents[path] != nil || isDirectory(path) else { throw VirtualFileSystem.Error.invalidPath(path) }
        return contents.keys.filter { path.isEmpty || $0 == path || $0.hasPrefix(path + "/") }.sorted()
    }

    func entries(under path: String = "") throws -> [Entry] {
        guard isDirectory(path) else { throw VirtualFileSystem.Error.notDirectory(path) }
        let prefix = path.isEmpty ? "" : path + "/"
        let descendants = try paths(under: path) + mounts.filter { $0.hasPrefix(prefix) }
        let children = Set(descendants.map { String($0.dropFirst(prefix.count).split(separator: "/")[0]) })
        return children.sorted().map {
            let relative = prefix + $0
            return Entry(path: relative, size: contents[relative]?.utf8.count)
        }
    }
}
