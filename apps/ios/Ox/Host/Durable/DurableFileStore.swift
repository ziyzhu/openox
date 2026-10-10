import Foundation
import CryptoKit
import Darwin

nonisolated final class DurableFileStore {
    private struct Handle {
        let fd: Int32
        let name: String
        let stage: String?
        let size: Int
        var directory: Int32 = -1
        var namespace = ""
        var offset = 0
        var hash = SHA256()
    }
    private let root: URL
    private let stateRoot: URL
    private let workspace: DurableWorkspaceStore
    private let privateWorkspace: DurableWorkspaceStore
    private var privateDirectory: Int32 = -1
    private var directory: Int32 = -1
    private var lock: Int32 = -1
    private var legacyLock: Int32 = -1
    private var handles: [String: Handle] = [:]
    private var closed = false
    private let chunkSize = 128 * 1024
    private var separated: Bool { stateRoot.standardizedFileURL.path != root.standardizedFileURL.path }

    init(root: URL, stateRoot: URL? = nil) {
        self.root = root; self.stateRoot = stateRoot ?? root
        workspace = DurableWorkspaceStore(root: root, stateRoot: stateRoot)
        privateWorkspace = DurableWorkspaceStore(root: stateRoot ?? root, privateContent: true)
    }
    deinit { close() }

    func perform(_ params: [String: Any]) throws -> Any {
        guard let op = params["op"] as? String else { throw failure("Invalid file operation") }
        if op == "close" { close(); return NSNull() }
        try acquire()
        switch op {
        case "workspaceInventory":
            return try workspace.inventory(previous: params["files"] as? [[String: Any]] ?? [])
        case "workspaceVerify":
            guard let path = params["path"] as? String, let size = params["size"] as? Int, size >= 0,
                  let digest = params["sha256"] as? String else { throw failure("Invalid file verification") }
            let source = payloadPath(path)
            try (source == nil ? workspace : privateWorkspace).verify(source ?? path, size: size, digest: digest)
            return NSNull()
        case "workspaceSweep":
            guard handles.isEmpty else { throw failure("Cannot sweep active file transfers") }
            var removed = 0
            for fd in [privateDirectory, directory] where fd >= 0 {
                for name in try workspace.entries(fd) where name.hasPrefix(".stage-") || name.hasPrefix(".write-") {
                    Darwin.close(try openFile(fd, name, flags: O_RDONLY))
                    guard unlinkat(fd, name, 0) == 0 else { throw posix("Remove orphaned staging") }
                    removed += 1
                }
                try durable(fd)
            }
            if removed > 0 { Log.agent.info("Filesystem.staging reclaimed files=\(removed)") }
            return NSNull()
        case "inventory":
            guard try legacyDirectory(create: false) else { return [String]() }
            return try workspace.entries(directory).filter { !$0.hasPrefix(".") }.map { "artifacts/" + $0 }
        case "retireLegacyOwner":
            if legacyLock >= 0 {
                var info = stat()
                guard fstat(legacyLock, &info) == 0, info.st_size == 0, info.st_nlink == 1,
                      unlinkat(directory, ".owner", 0) == 0 else { throw failure("Invalid predecessor owner lock") }
                try durable(directory)
                Darwin.close(legacyLock); legacyLock = -1
            }
            return NSNull()
        case "workspaceApply", "workspaceValidate", "workspacePreparePending":
            guard let operations = params["operations"] as? [[String: Any]] else { throw failure("Invalid file operations") }
            do {
                let publicOperations = operations.filter { payloadPath($0["path"] as? String ?? "") == nil }
                let privateOperations = operations.filter { payloadPath($0["path"] as? String ?? "") != nil }.map { operation in
                    var translated = operation
                    translated["path"] = payloadPath(operation["path"] as! String)
                    return translated
                }
                for (store, mutations) in [(workspace, publicOperations), (privateWorkspace, privateOperations)] where !mutations.isEmpty {
                    if op == "workspaceValidate" { try store.validate(mutations) }
                    else { try store.apply(mutations, preparingLegacy: op == "workspacePreparePending") }
                }
            } catch {
                let failure = error as NSError
                if op == "workspaceApply", failure.domain == "OxDurablePayload" ||
                    (failure.domain == "OxWorkspace" && [ENOENT, EEXIST, ENOTEMPTY, EACCES, ELOOP].contains(Int32(failure.code))) {
                    Log.agent.warning("Filesystem.recovery conflict operations=\(operations.count) domain=\(failure.domain) code=\(failure.code)")
                    return ["conflict": true]
                }
                throw error
            }
            if op == "workspacePreparePending" { Log.agent.info("Filesystem.recovery predecessor operations=\(operations.count)") }
            return NSNull()
        case "workspaceOpen":
            guard handles.count < 4, let path = params["path"] as? String, let size = params["size"] as? Int,
                  (0...32 * 1024 * 1024).contains(size) else { throw failure("Invalid file read") }
            let source = payloadPath(path)
            let fd = try (source == nil ? workspace : privateWorkspace).openFile(source ?? path)
            try checkSize(fd, size: size)
            let token = UUID().uuidString
            handles[token] = Handle(fd: fd, name: path, stage: nil, size: size)
            return token
        case "workspaceReadRange", "payloadVerify", "payloadRead":
            guard let path = params["path"] as? String, let size = params["size"] as? Int, size >= 0,
                  let digest = params["sha256"] as? String else { throw failure("Invalid file range") }
            if op != "workspaceReadRange" {
                guard path == "artifacts/payload-" + digest + ".json" else { throw failure("Invalid predecessor payload") }
            }
            let source = payloadPath(path)
            let fd = try (source == nil ? workspace : privateWorkspace).openFile(source ?? path)
            defer { Darwin.close(fd) }
            try DurablePayloadWriter.verify(fd, size: size, digest: digest)
            if op == "payloadVerify" { return NSNull() }
            guard let offset = params["offset"] as? Int, let length = params["length"] as? Int,
                  length <= 32 * 1024 * 1024 else { throw failure("File range exceeds the read limit") }
            return try range(fd, size: size, offset: offset, length: length).base64EncodedString()
        case "release":
            if let token = params["token"] as? String { release(token) }
            return NSNull()
        case "begin", "workspaceStage", "open", "flush":
            let isPrivate = op == "workspaceStage"
            if !isPrivate { _ = try legacyDirectory(create: true) }
            let target = isPrivate ? privateDirectory : directory
            let name = isPrivate ? ".stage-" + UUID().uuidString : try basename(params["path"] as? String)
            if op == "flush" {
                let fd = try openFile(target, name, flags: O_RDONLY)
                defer { Darwin.close(fd) }
                try durable(fd); try durable(target)
                return NSNull()
            }
            guard handles.count < 4, let size = params["size"] as? Int, (0...32 * 1024 * 1024).contains(size) else { throw failure("File size or transfer limit exceeded") }
            let token = UUID().uuidString
            if op == "begin" || isPrivate {
                let stage = ".write-\(token)"
                let fd = openat(target, stage, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw posix("Stage file") }
                handles[token] = Handle(fd: fd, name: name, stage: stage, size: size,
                    directory: target, namespace: isPrivate ? (separated ? "staging" : ".files") : "artifacts")
            } else {
                let fd = try openFile(target, name, flags: O_RDONLY)
                try checkSize(fd, size: size)
                handles[token] = Handle(fd: fd, name: name, stage: nil, size: size)
            }
            return token
        default:
            break
        }
        guard let token = params["token"] as? String, var handle = handles[token] else { throw failure("File transfer expired") }
        if op == "write" || op == "read" {
            guard let offset = params["offset"] as? Int, offset == handle.offset else { throw failure("Invalid file offset") }
            if op == "write" {
                guard handle.stage != nil, let bytes = params["bytes"] as? [UInt8], !bytes.isEmpty,
                      bytes.count <= chunkSize, offset + bytes.count <= handle.size else { throw failure("Invalid file write") }
                let data = Data(bytes)
                try data.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let count = pwrite(handle.fd, buffer.baseAddress!.advanced(by: written), buffer.count - written, off_t(offset + written))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw posix("Write file") }
                        written += count
                    }
                }
                handle.hash.update(data: data); handle.offset += bytes.count
                handles[token] = handle
                return NSNull()
            }
            guard handle.stage == nil, let length = params["length"] as? Int, (1...chunkSize).contains(length),
                  offset + length <= handle.size else { throw failure("Invalid file read") }
            let data = try range(handle.fd, size: handle.size, offset: offset, length: length)
            handle.hash.update(data: data); handle.offset += length
            handles[token] = handle
            return Array(data)
        }
        guard handle.offset == handle.size else { throw failure("File transfer is incomplete") }
        let digest = handle.hash.finalize().map { String(format: "%02x", $0) }.joined()
        if op == "verify" {
            guard handle.stage == nil, params["sha256"] as? String == digest else { throw failure("File digest does not match committed metadata") }
            return NSNull()
        }
        if op == "publish", let stage = handle.stage {
            try durable(handle.fd)
            guard linkat(handle.directory, stage, handle.directory, handle.name, 0) == 0 else { throw posix("Stage destination already exists") }
            guard unlinkat(handle.directory, stage, 0) == 0 else { throw posix("Remove transfer staging") }
            try durable(handle.directory)
            return ["path": "\(handle.namespace)/\(handle.name)", "size": handle.size, "sha256": digest]
        }
        throw failure("Unknown file operation")
    }

    func capturePayload(_ reference: JSONValue, offset: Int, length: Int) throws -> Data {
        try acquire()
        guard let fields = reference.objectValue, let path = fields["path"]?.stringValue,
              let size = fields["size"]?.intValue, let digest = fields["sha256"]?.stringValue,
              path == "artifacts/payload-" + digest + ".json", length <= 64 * 1024 * 1024 else { throw failure("Invalid bounded payload capture") }
        let source = payloadPath(path)
        let fd = try (source == nil ? workspace : privateWorkspace).openFile(source ?? path)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size else { throw failure("Payload capture size mismatch") }
        return try range(fd, size: size, offset: offset, length: length)
    }

    func payloadWriter() throws -> DurablePayloadWriter {
        try acquire()
        _ = try legacyDirectory(create: true)
        return try DurablePayloadWriter(directory: directory)
    }

    func acquire() throws {
        guard !closed else { throw failure("File owner closed; reacquire after reopening") }
        if privateDirectory >= 0 { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let parent = open(stateRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posix("Open Profile state scope") }
        defer { Darwin.close(parent) }
        let staging = separated ? "staging" : ".files"
        guard mkdirat(parent, staging, 0o700) == 0 || errno == EEXIST else { throw posix("Create private file scope") }
        let dir = openat(parent, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw posix("Pin private file scope") }
        let owner = openat(dir, ".owner", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard owner >= 0 else { Darwin.close(dir); throw posix("Open file ownership lock") }
        var ownership = stat()
        guard fstat(owner, &ownership) == 0, ownership.st_mode & S_IFMT == S_IFREG, ownership.st_nlink == 1 else {
            Darwin.close(owner); Darwin.close(dir); throw failure("File owner lock must be an owned regular file")
        }
        guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(owner); Darwin.close(dir); throw failure("Profile files already have an owner") }
        privateDirectory = dir; lock = owner
        _ = try legacyDirectory(create: false)
        try durable(parent)
    }

    func close() {
        guard !closed else { return }
        for token in Array(handles.keys) { release(token) }
        for fd in [lock, legacyLock, directory, privateDirectory] where fd >= 0 { Darwin.close(fd) }
        lock = -1; legacyLock = -1; directory = -1; privateDirectory = -1
        closed = true
    }

    private func legacyDirectory(create: Bool) throws -> Bool {
        if directory >= 0 { return true }
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posix("Pin predecessor file scope") }
        defer { Darwin.close(parent) }
        if create {
            guard mkdirat(parent, "artifacts", 0o700) == 0 || errno == EEXIST else { throw posix("Create predecessor file directory") }
        }
        let dir = openat(parent, "artifacts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if dir < 0, errno == ENOENT, !create { return false }
        guard dir >= 0 else { throw posix("Pin predecessor directory") }
        let owner = openat(dir, ".owner", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if owner < 0, errno != ENOENT { Darwin.close(dir); throw posix("Open predecessor ownership lock") }
        if owner >= 0 {
            var info = stat()
            guard fstat(owner, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  flock(owner, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(owner); Darwin.close(dir); throw failure("Predecessor files already have an owner")
            }
        }
        directory = dir; legacyLock = owner
        return true
    }

    private func payloadPath(_ path: String) -> String? {
        if separated, path.hasPrefix("payloads/") { return path }
        guard separated, path.hasPrefix("artifacts/payload-"), path.hasSuffix(".json"),
              path.dropFirst(18).dropLast(5).count == 64, path.dropFirst(18).dropLast(5).allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return "payloads/" + path.dropFirst(10)
    }

    private func checkSize(_ fd: Int32, size: Int) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size else { Darwin.close(fd); throw failure("File size mismatch") }
    }

    private func openFile(_ directory: Int32, _ name: String, flags: Int32) throws -> Int32 {
        let fd = openat(directory, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posix("Open file") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { Darwin.close(fd); throw failure("File must be an owned regular file") }
        return fd
    }

    private func range(_ fd: Int32, size: Int, offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= size, length <= size - offset else { throw failure("File range is outside its contents") }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var read = 0
            while read < length {
                let count = pread(fd, buffer.baseAddress!.advanced(by: read), length - read, off_t(offset + read))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("File range was truncated") }
                read += count
            }
        }
        return data
    }

    private func basename(_ path: String?) throws -> String {
        guard let path, path.hasPrefix("artifacts/") else { throw failure("Expected a predecessor file path") }
        let name = String(path.dropFirst(10))
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure("Invalid predecessor filename") }
        return name
    }

    private func release(_ token: String) {
        guard let handle = handles.removeValue(forKey: token) else { return }
        Darwin.close(handle.fd)
        if let stage = handle.stage, unlinkat(handle.directory, stage, 0) != 0, errno != ENOENT { Log.agent.warning("Filesystem.staging cleanupFailed errno=\(errno)") }
    }

    private func durable(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw posix("Synchronize file") }
        if fcntl(fd, F_FULLFSYNC) != 0, errno != ENOTSUP, errno != EINVAL { throw posix("Flush file device") }
    }

    private func posix(_ operation: String) -> NSError {
        let code = errno
        return failure("\(operation): \(String(cString: strerror(code)))", code: Int(code))
    }

    private func failure(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "OxDurableFiles", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
