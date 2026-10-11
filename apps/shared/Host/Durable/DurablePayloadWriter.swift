import Foundation
import CryptoKit
import Darwin

nonisolated final class DurablePayloadWriter {
    static let inlineLimit = 16 * 1024
    private enum State { case writing, published }
    private var state = State.writing
    private let directory: Int32
    private let descriptor: Int32
    private let stage = ".payload-" + UUID().uuidString
    private var hash = SHA256()
    private(set) var size = 0

    init(directory: Int32) throws {
        self.directory = dup(directory)
        guard self.directory >= 0 else { throw Self.failure("Pin payload directory") }
        descriptor = openat(self.directory, stage, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            Darwin.close(self.directory)
            throw Self.failure("Create payload stage")
        }
    }

    deinit {
        Darwin.close(descriptor)
        unlinkat(directory, stage, 0)
        Darwin.close(directory)
    }

    func append(_ data: Data) throws {
        guard state == .writing else { throw Self.failure("Published payloads are immutable") }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.failure("Write payload") }
                offset += count
            }
        }
        hash.update(data: data)
        size += data.count
    }

    func read(offset: Int, length: Int) throws -> Data {
        guard state == .writing else { throw Self.failure("Payload capture is closed") }
        guard offset >= 0, length >= 0, length <= 64 * 1024, offset <= size, length <= size - offset else {
            throw Self.failure("Invalid bounded payload capture")
        }
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var read = 0
            while read < length {
                let count = pread(descriptor, buffer.baseAddress!.advanced(by: read), length - read, off_t(offset + read))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Self.failure("Read payload capture") }
                read += count
            }
        }
        return data
    }

    func finish() throws -> JSONValue {
        guard state == .writing else { throw Self.failure("Payload is already published") }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let name = "payload-" + digest + ".json"
        guard fsync(descriptor) == 0 else { throw Self.failure("Synchronize payload") }
        if linkat(directory, stage, directory, name, 0) != 0 {
            guard errno == EEXIST else { throw Self.failure("Publish payload") }
            let existing = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard existing >= 0 else { throw Self.failure("Pin existing payload") }
            defer { Darwin.close(existing) }
            try Self.verify(existing, size: size, digest: digest)
        }
        state = .published
        guard unlinkat(directory, stage, 0) == 0, fsync(directory) == 0 else { throw Self.failure("Synchronize payload publication") }
        return .object(["path": .string("artifacts/" + name), "size": .int(size), "sha256": .string(digest)])
    }

    static func verify(_ descriptor: Int32, size: Int, digest: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size == size else { throw failure("Payload must match an immutable regular file") }
        var hash = SHA256()
        var offset = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while offset < size {
            let count = pread(descriptor, &buffer, min(buffer.count, size - offset), off_t(offset))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure("Payload was truncated") }
            hash.update(data: Data(buffer.prefix(count)))
            offset += count
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw failure("Payload digest mismatch") }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw failure("Payload changed during verification") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "OxDurablePayload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
