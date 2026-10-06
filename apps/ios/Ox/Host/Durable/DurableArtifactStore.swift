import Foundation
import CryptoKit
import Darwin

/// One native-queue owner. Paths are resolved by openat on a pinned directory,
/// never by a check-then-open URL or the mutable active Profile.
/// Files are immutable publications; logical removal cannot erase historical content.
/// Apple: https://developer.apple.com/documentation/foundation/filehandle/synchronize()
nonisolated final class DurableArtifactStore {
    private struct Handle {
        let fd: Int32
        let name: String
        let stage: String?
        let size: Int
        var offset = 0
        var hash = SHA256()
    }
    private let root: URL
    private var directory: Int32 = -1
    private var lock: Int32 = -1
    private var handles: [String: Handle] = [:]
    private var closed = false
    private let chunkSize = 128 * 1024
    init(root: URL) { self.root = root }
    deinit { close() }

    func perform(_ params: [String: Any]) throws -> Any {
        guard let op = params["op"] as? String else { throw failure("Invalid artifact operation") }
        if op == "close" { close(); return NSNull() }
        guard !closed else { throw failure("Artifact owner closed; reacquire after reopening") }
        try prepare()
        if op == "payloadVerify" || op == "payloadRead" {
            let name = try basename(params["path"] as? String)
            guard let size = params["size"] as? Int, size >= 0, let digest = params["sha256"] as? String,
                  name == "payload-" + digest + ".json", digest.count == 64,
                  digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw failure("Invalid payload reference") }
            let fd = try openFile(name, flags: O_RDONLY)
            defer { Darwin.close(fd) }
            try DurablePayloadWriter.verify(fd, size: size, digest: digest)
            if op == "payloadVerify" { return NSNull() }
            guard let offset = params["offset"] as? Int, let length = params["length"] as? Int,
                  offset >= 0, length >= 0, length <= 32 * 1024 * 1024, offset <= size, length <= size - offset else {
                throw failure("Payload range exceeds the bounded read limit")
            }
            var data = Data(count: length)
            try data.withUnsafeMutableBytes { buffer in
                var read = 0
                while read < length {
                    let count = pread(fd, buffer.baseAddress!.advanced(by: read), length - read, off_t(offset + read))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure("Payload range was truncated") }
                    read += count
                }
            }
            return data.base64EncodedString()
        }
        if op == "release" {
            if let token = params["token"] as? String { release(token) }
            return NSNull()
        }
        if op == "begin" || op == "open" || op == "flush" {
            let name = try basename(params["path"] as? String)
            if op == "flush" {
                let fd = try openFile(name, flags: O_RDONLY)
                defer { Darwin.close(fd) }
                try durable(fd); try directorySync()
                return NSNull()
            }
            guard handles.count < 4, let size = params["size"] as? Int, (0...32 * 1024 * 1024).contains(size) else {
                throw failure("Invalid artifact size or too many open handles")
            }
            let token = UUID().uuidString
            if op == "begin" {
                let stage = ".write-\(token)"
                let fd = openat(directory, stage, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw posix("Stage artifact") }
                handles[token] = Handle(fd: fd, name: name, stage: stage, size: size)
            } else {
                let fd = try openFile(name, flags: O_RDONLY)
                var stat = stat()
                guard fstat(fd, &stat) == 0, stat.st_size == size else {
                    Darwin.close(fd); throw failure("Artifact size does not match committed reference")
                }
                handles[token] = Handle(fd: fd, name: name, stage: nil, size: size)
            }
            return token
        }
        guard let token = params["token"] as? String, var handle = handles[token] else { throw failure("Artifact handle expired") }
        if op == "write" || op == "read" {
            guard let offset = params["offset"] as? Int, offset == handle.offset else { throw failure("Invalid artifact offset") }
            if op == "write" {
                guard handle.stage != nil, let bytes = params["bytes"] as? [UInt8], !bytes.isEmpty,
                      bytes.count <= chunkSize, offset + bytes.count <= handle.size else { throw failure("Invalid artifact write") }
                let data = Data(bytes)
                try data.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let count = pwrite(handle.fd, buffer.baseAddress!.advanced(by: written), buffer.count - written, off_t(offset + written))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw posix("Write artifact") }
                        written += count
                    }
                }
                handle.hash.update(data: data); handle.offset += bytes.count
                handles[token] = handle
                return NSNull()
            }
            guard handle.stage == nil, let length = params["length"] as? Int, (1...chunkSize).contains(length),
                  offset + length <= handle.size else { throw failure("Invalid artifact read") }
            var data = Data(count: length)
            try data.withUnsafeMutableBytes { buffer in
                var read = 0
                while read < length {
                    let count = pread(handle.fd, buffer.baseAddress!.advanced(by: read), length - read, off_t(offset + read))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw failure("Artifact missing or truncated during read") }
                    read += count
                }
            }
            handle.hash.update(data: data); handle.offset += length
            handles[token] = handle
            return Array(data)
        }
        guard handle.offset == handle.size else { throw failure("Artifact transfer is incomplete") }
        let digest = handle.hash.finalize().map { String(format: "%02x", $0) }.joined()
        if op == "verify" {
            guard handle.stage == nil, params["sha256"] as? String == digest else { throw failure("Artifact digest does not match committed reference") }
            return NSNull()
        }
        if op == "publish", let stage = handle.stage {
            try durable(handle.fd)
            // linkat is atomic and refuses existing names; rename would overwrite an old reference.
            guard linkat(directory, stage, directory, handle.name, 0) == 0 else { throw posix("Publish artifact; choose a distinct filename") }
            guard unlinkat(directory, stage, 0) == 0 else { throw posix("Remove artifact staging link") }
            try directorySync()
            return ["path": "artifacts/\(handle.name)", "size": handle.size, "sha256": digest]
        }
        throw failure("Unknown artifact operation")
    }

    func capturePayload(_ reference: JSONValue, offset: Int, length: Int) throws -> Data {
        guard !closed else { throw failure("Payload owner closed") }
        try prepare()
        guard let fields = reference.objectValue, let path = fields["path"]?.stringValue,
              let size = fields["size"]?.intValue, let digest = fields["sha256"]?.stringValue,
              path == "artifacts/payload-" + digest + ".json", offset >= 0, length >= 0,
              length <= 64 * 1024 * 1024, offset <= size, length <= size - offset else {
            throw failure("Invalid bounded payload capture")
        }
        let fd = try openFile(try basename(path), flags: O_RDONLY)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size == size else { throw failure("Payload capture size mismatch") }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var read = 0
            while read < length {
                let count = pread(fd, buffer.baseAddress!.advanced(by: read), length - read, off_t(offset + read))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw failure("Payload capture was truncated") }
                read += count
            }
        }
        return data
    }

    func payloadWriter() throws -> DurablePayloadWriter {
        guard !closed else { throw failure("Payload owner closed") }
        try prepare()
        return try DurablePayloadWriter(directory: directory)
    }

    func acquire() throws {
        guard !closed else { throw failure("Artifact owner closed; reacquire after reopening") }
        try prepare()
    }

    func close() {
        guard !closed else { return }
        for token in Array(handles.keys) { release(token) }
        if lock >= 0 { Darwin.close(lock); lock = -1 }
        if directory >= 0 { Darwin.close(directory); directory = -1 }
        closed = true
    }
    private func prepare() throws {
        if directory >= 0 { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw posix("Open immutable artifact scope") }
        defer { Darwin.close(parent) }
        guard mkdirat(parent, "artifacts", 0o700) == 0 || errno == EEXIST else { throw posix("Create artifacts") }
        let dir = openat(parent, "artifacts", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw posix("Open artifact directory") }
        let owner = openat(dir, ".owner", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard owner >= 0 else { Darwin.close(dir); throw posix("Open artifact ownership lock") }
        var ownership = stat()
        guard fstat(owner, &ownership) == 0, ownership.st_mode & S_IFMT == S_IFREG, ownership.st_nlink == 1 else {
            Darwin.close(owner); Darwin.close(dir); throw failure("Artifact owner lock must be an owned regular file")
        }
        guard flock(owner, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(owner); Darwin.close(dir); throw failure("Artifact scope already has an owner") }
        directory = dir; lock = owner
        try durable(parent)
    }
    private func openFile(_ name: String, flags: Int32) throws -> Int32 {
        let fd = openat(directory, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw posix("Open artifact") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(fd); throw failure("Artifact must be an owned regular file, not a link or device")
        }
        return fd
    }
    private func basename(_ path: String?) throws -> String {
        guard let path, path.hasPrefix("artifacts/") else { throw failure("Expected a Profile-relative artifact path") }
        let name = String(path.dropFirst(10))
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure("Invalid artifact filename") }
        return name
    }
    private func release(_ token: String) {
        guard let handle = handles.removeValue(forKey: token) else { return }
        Darwin.close(handle.fd)
        if let stage = handle.stage, unlinkat(directory, stage, 0) != 0, errno != ENOENT {
            Log.agent.warning("PiDurable artifact staging cleanup failed errno=\(errno)")
        }
    }
    private func durable(_ fd: Int32) throws {
        guard fsync(fd) == 0 else { throw posix("Synchronize artifact") }
        // F_FULLFSYNC requests the device flush as well. Some directory/Simulator
        // filesystems do not implement it; fsync is the explicit supported fallback.
        if fcntl(fd, F_FULLFSYNC) != 0, errno != ENOTSUP, errno != EINVAL { throw posix("Flush artifact device") }
    }
    private func directorySync() throws { try durable(directory) }
    private func posix(_ operation: String) -> NSError {
        let code = errno
        return failure("\(operation): \(String(cString: strerror(code)))", code: Int(code))
    }
    private func failure(_ message: String, code: Int = 1) -> NSError {
        NSError(domain: "OxDurableArtifacts", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
