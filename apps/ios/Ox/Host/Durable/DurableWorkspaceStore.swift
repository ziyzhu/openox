import Foundation
import Darwin
import CryptoKit

nonisolated final class DurableWorkspaceStore {
    private let root: URL
    private var descriptor: Int32 = -1
    private let stateRoot: URL
    private var stateDescriptor: Int32 = -1
    private let privateContent: Bool

    init(root: URL, stateRoot: URL? = nil, privateContent: Bool = false) { self.root = root; self.stateRoot = stateRoot ?? root; self.privateContent = privateContent }
    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if stateDescriptor >= 0 { Darwin.close(stateDescriptor) }
    }

    private func prepare() throws {
        if descriptor >= 0 {
            var pinned = stat(), current = stat()
            if fstat(descriptor, &pinned) == 0, lstat(root.path, &current) == 0,
               current.st_mode & S_IFMT == S_IFDIR, current.st_dev == pinned.st_dev, current.st_ino == pinned.st_ino { return }
            Darwin.close(descriptor); descriptor = -1
        }
        descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("Open workspace scope") }
    }

    private func components(_ path: String, privateStage: Bool = false) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if privateStage, parts.count == 2, ["artifacts", ".files", "staging"].contains(parts[0]), parts[1].hasPrefix(".stage-"), UUID(uuidString: String(parts[1].dropFirst(7))) != nil { return parts }
        let reserved = (privateContent ? [] : ["payloads"]) + ["profile.json", "state.sqlite", "state.sqlite-wal", "state.sqlite-shm", "skill-selections.json", "services", "files", "history", "chats"]
        guard !path.isEmpty, path.utf8.count <= 4096, parts.count <= 64,
              !reserved.contains(parts[0].lowercased()), !parts[0].lowercased().hasPrefix("state.sqlite-"), parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0.utf8.count <= 240 && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else {
            throw failure("Invalid workspace path", code: EACCES)
        }
        if parts[0] == "conversations", parts.count > 1 {
            guard let id = Int(parts[1]), id >= 0, String(id) == parts[1] else { throw failure("Invalid conversation directory", code: EINVAL) }
        }
        return parts
    }

    private func parent(_ path: String, privateStage: Bool = false) throws -> (Int32, String) {
        try prepare()
        let parts = try components(path, privateStage: privateStage)
        let usePrivateStage = privateStage && parts[0] == "staging"
        if usePrivateStage && stateDescriptor < 0 {
            stateDescriptor = open(stateRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stateDescriptor >= 0 else { throw failure("Pin private staging scope") }
        }
        var current = dup(usePrivateStage ? stateDescriptor : descriptor)
        guard current >= 0 else { throw failure("Pin workspace directory") }
        do {
            for part in parts.dropLast() {
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw failure("Open workspace parent") }
                Darwin.close(current); current = next
            }
            return (current, parts.last!)
        } catch { Darwin.close(current); throw error }
    }

    func openFile(_ path: String, privateStage: Bool = false) throws -> Int32 {
        let (directory, name) = try parent(path, privateStage: privateStage)
        defer { Darwin.close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Open workspace file") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw failure("Workspace file must be an owned regular file", code: EACCES)
        }
        return fd
    }

    func verify(_ path: String, size: Int, digest: String, privateStage: Bool = false) throws {
        let fd = try openFile(path, privateStage: privateStage)
        defer { Darwin.close(fd) }
        try DurablePayloadWriter.verify(fd, size: size, digest: digest)
    }

    private func existing(_ directory: Int32, _ name: String, directory expectedDirectory: Bool) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw failure("Inspect workspace destination")
        }
        guard info.st_mode & S_IFMT == (expectedDirectory ? S_IFDIR : S_IFREG), expectedDirectory || info.st_nlink == 1 else {
            throw failure("Workspace destination is a link or has the wrong type", code: EACCES)
        }
        return true
    }

    func entries(_ fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw failure("Pin directory listing") }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw failure("Read workspace directory") }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
            guard names.count <= 10_000 else { throw failure("Directory exceeds entry limit", code: EINVAL) }
        }
        return names
    }

    func inventory(previous: [[String: Any]]) throws -> [String: Any] {
        do { try prepare() }
        catch {
            if (error as NSError).code == Int(ENOENT) { return ["files": [[String: Any]](), "directories": [String]()] }
            throw error
        }
        let known = Dictionary(previous.compactMap { file -> (String, [String: Any])? in
            guard let path = file["path"] as? String else { return nil }
            return (path, file)
        }, uniquingKeysWith: { first, _ in first })
        var files: [[String: Any]] = []
        var directories: [String] = []
        var count = 0
        var bytes = 0
        var ignored = 0
        func visit(_ directory: Int32, _ prefix: String) throws {
            for name in try entries(directory) {
                count += 1
                let path = prefix.isEmpty ? name : prefix + "/" + name
                bytes += path.utf8.count
                guard count <= 10_000, bytes <= 4 * 1024 * 1024 else { throw failure("Workspace inventory exceeds limit", code: EINVAL) }
                do { _ = try components(path) }
                catch { ignored += 1; continue }
                var info = stat()
                if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }
                    throw failure("Inspect external workspace entry")
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw failure("Pin workspace inventory directory") }
                    defer { Darwin.close(fd) }
                    directories.append(path)
                    try visit(fd, path)
                } else if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, (0...32 * 1024 * 1024).contains(info.st_size) {
                    let stamp = "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_size)"
                    let mtime = Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000
                    if let cached = known[path], cached["stamp"] as? String == stamp,
                       let digest = cached["sha256"] as? String, let binary = cached["binary"] as? Bool {
                        files.append(["path": path, "size": Int(info.st_size), "sha256": digest, "binary": binary, "mtime": mtime, "stamp": stamp])
                        continue
                    }
                    let fd = try openFile(path)
                    defer { Darwin.close(fd) }
                    var pinned = stat()
                    guard fstat(fd, &pinned) == 0, pinned.st_dev == info.st_dev, pinned.st_ino == info.st_ino else { throw failure("Workspace entry changed during inventory", code: EBUSY) }
                    var hash = SHA256()
                    var text = Data()
                    var offset = 0
                    var buffer = [UInt8](repeating: 0, count: 128 * 1024)
                    while offset < info.st_size {
                        let read = pread(fd, &buffer, min(buffer.count, Int(info.st_size) - offset), off_t(offset))
                        if read < 0 && errno == EINTR { continue }
                        guard read > 0 else { throw failure("Workspace file changed during inventory", code: EBUSY) }
                        let data = Data(buffer.prefix(read))
                        hash.update(data: data)
                        if info.st_size <= 200 * 1024 { text.append(data) }
                        offset += read
                    }
                    var after = stat()
                    guard fstat(fd, &after) == 0, after.st_size == info.st_size,
                          after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
                          after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
                        throw failure("Workspace file changed during inventory", code: EBUSY)
                    }
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    let binary = info.st_size > 200 * 1024 || text.contains(0) || String(data: text, encoding: .utf8) == nil
                    files.append(["path": path, "size": offset, "sha256": digest, "binary": binary, "mtime": mtime, "stamp": stamp])
                } else { ignored += 1 }
            }
        }
        try visit(descriptor, "")
        if ignored > 0 { Log.agent.info("Workspace.inventory ignored entries=\(ignored)") }
        return ["files": files, "directories": directories]
    }

    private func validateReplacement(_ operation: [String: Any], directory: Int32, name: String, path: String) throws {
        let present = try existing(directory, name, directory: false)
        if let previous = operation["previous"] as? [String: Any], let size = previous["size"] as? Int, let digest = previous["sha256"] as? String {
            guard present else { throw failure("File disappeared before replacement", code: ENOENT) }
            try verify(path, size: size, digest: digest)
        } else if present { throw failure("Untracked destination already exists", code: EEXIST) }
    }

    func validate(_ operations: [[String: Any]]) throws {
        guard operations.count <= 20_000 else { throw failure("Workspace mutation exceeds entry limit", code: EINVAL) }
        let created = Set(operations.filter { $0["op"] as? String == "mkdir" }.compactMap { $0["path"] as? String })
        let departures = Set(operations.compactMap { operation -> String? in
            if operation["op"] as? String == "remove" { return operation["path"] as? String }
            if operation["op"] as? String == "move" { return operation["source"] as? String }
            return nil
        })
        for operation in operations {
            guard let op = operation["op"] as? String, let path = operation["path"] as? String else { throw failure("Invalid workspace mutation", code: EINVAL) }
            if let source = operation["source"] as? String, let size = operation["size"] as? Int, let digest = operation["sha256"] as? String {
                try verify(source, size: size, digest: digest, privateStage: op == "replace")
            }
            let directory: Int32, name: String
            do { (directory, name) = try parent(path) }
            catch {
                let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                if (error as NSError).code == Int(ENOENT), created.contains(parentPath), op == "mkdir" || op == "replace" || op == "move" { continue }
                throw error
            }
            defer { Darwin.close(directory) }
            switch op {
            case "mkdir":
                _ = try existing(directory, name, directory: true)
            case "replace":
                try validateReplacement(operation, directory: directory, name: name, path: path)
            case "move":
                guard !(try existing(directory, name, directory: false)) else { throw failure("Destination already exists", code: EEXIST) }
                guard let source = operation["source"] as? String, let size = operation["size"] as? Int, let digest = operation["sha256"] as? String else { throw failure("Invalid move", code: EINVAL) }
                try verify(source, size: size, digest: digest)
            case "remove":
                let isDirectory = operation["directory"] as? Bool == true
                guard try existing(directory, name, directory: isDirectory) else { throw failure("Entry disappeared before deletion", code: ENOENT) }
                if isDirectory {
                    let fd = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw failure("Pin directory removal") }
                    defer { Darwin.close(fd) }
                    guard try entries(fd).allSatisfy({ departures.contains(path + "/" + $0) }) else { throw failure("Directory contains untracked files", code: ENOTEMPTY) }
                }
            default:
                throw failure("Unknown workspace mutation", code: EINVAL)
            }
        }
    }

    func apply(_ operations: [[String: Any]], preparingLegacy: Bool = false) throws {
        guard operations.count <= 20_000 else { throw failure("Workspace mutation exceeds entry limit", code: EINVAL) }
        for operation in operations {
            guard let op = operation["op"] as? String, let path = operation["path"] as? String else { throw failure("Invalid workspace mutation", code: EINVAL) }
            let directory: Int32, name: String
            do { (directory, name) = try parent(path) }
            catch {
                if op == "remove", (error as NSError).code == Int(ENOENT) { continue }
                throw error
            }
            defer { Darwin.close(directory) }
            switch op {
            case "mkdir":
                if !(try existing(directory, name, directory: true)) {
                    guard mkdirat(directory, name, 0o700) == 0 else { throw failure("Create workspace directory") }
                }
            case "remove":
                guard let isDirectory = operation["directory"] as? Bool else { throw failure("Invalid removal", code: EINVAL) }
                if try existing(directory, name, directory: isDirectory) {
                    guard unlinkat(directory, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else { throw failure("Remove workspace entry") }
                }
            case "replace", "move":
                guard let source = operation["source"] as? String, let size = operation["size"] as? Int,
                      let digest = operation["sha256"] as? String, (0...32 * 1024 * 1024).contains(size),
                      digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                      op != "replace" || source.hasPrefix("staging/.stage-") || source.hasPrefix(".files/.stage-") || source.hasPrefix("artifacts/.stage-") else { throw failure("Invalid file mutation", code: EINVAL) }
                let sourceDirectory: Int32, sourceName: String
                do { (sourceDirectory, sourceName) = try parent(source, privateStage: op == "replace") }
                catch {
                    if (error as NSError).code == Int(ENOENT) {
                        try verify(path, size: size, digest: digest)
                        break
                    }
                    throw error
                }
                defer { Darwin.close(sourceDirectory) }
                let sourceExists = try existing(sourceDirectory, sourceName, directory: false)
                if !sourceExists {
                    try verify(path, size: size, digest: digest)
                    break
                }
                try verify(source, size: size, digest: digest, privateStage: op == "replace")
                let destinationExists = try existing(directory, name, directory: false)
                guard op == "replace" || !destinationExists else { throw failure("Move destination already exists", code: EEXIST) }
                if op == "replace", !(preparingLegacy && operation["previous"] == nil && source.hasPrefix("artifacts/.stage-")) {
                    try validateReplacement(operation, directory: directory, name: name, path: path)
                }
                guard renameatx_np(sourceDirectory, sourceName, directory, name, op == "move" ? UInt32(RENAME_EXCL) : 0) == 0 else { throw failure("Publish workspace file") }
                try synchronize(sourceDirectory)
            default:
                throw failure("Unknown workspace mutation", code: EINVAL)
            }
            try synchronize(directory)
        }
        Log.agent.info("Workspace.apply completed operations=\(operations.count)")
    }

    private func synchronize(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw failure("Synchronize workspace") }
        if fcntl(fd, F_FULLFSYNC) != 0, errno != ENOTSUP, errno != EINVAL { throw failure("Flush workspace device") }
    }

    private func failure(_ operation: String, code: Int32? = nil) -> NSError {
        let value = code ?? errno
        return NSError(domain: "OxWorkspace", code: Int(value), userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(value)))"])
    }
}
