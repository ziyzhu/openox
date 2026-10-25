import Foundation
import Synchronization

nonisolated final class ProviderFileInputs: Sendable {
    nonisolated private struct Group: Sendable {
        var sources: [URL: FileItem] = [:]
        var bytes: [URL: Data] = [:]
        var size = 0
    }

    private static let groups = Mutex<[UUID: Group]>([:])
    private let id = UUID()

    init() {
        Self.groups.withLock { $0[id] = Group() }
    }

    deinit {
        Self.groups.withLock { _ = $0.removeValue(forKey: id) }
    }

    func snapshot(_ file: FileItem, data: Data) throws -> FileItem {
        try Self.groups.withLock { groups in
            guard var group = groups[id] else { throw RuntimeError.bridge("Provider file input scope is closed") }
            if let existing = group.sources[file.fileURL] {
                guard group.bytes[existing.fileURL] == data else { throw RuntimeError.bridge("Immutable file changed during model input preparation") }
                return existing
            }
            guard data.count <= FileLimits.fileBytes, group.size + data.count <= 4 * FileLimits.fileBytes else {
                throw RuntimeError.bridge("Verified provider file inputs exceed their bounded memory budget")
            }
            let directory = URL(string: "ox-model-input://\(id.uuidString)/\(UUID().uuidString)/")!
            let snapshot = FileItem(fileName: file.fileName, directory: directory, relativePath: file.displayName,
                                    virtualPath: file.virtualPath, size: data.count)
            group.sources[file.fileURL] = snapshot
            group.bytes[snapshot.fileURL] = data
            group.size += data.count
            groups[id] = group
            return snapshot
        }
    }

    var footprint: (files: Int, bytes: Int) {
        Self.groups.withLock { groups in
            guard let group = groups[id] else { return (0, 0) }
            return (group.bytes.count, group.size)
        }
    }

    func cached(_ file: FileItem) -> FileItem? {
        Self.groups.withLock { $0[id]?.sources[file.fileURL] }
    }

    static func read(_ file: FileItem) throws -> Data {
        guard file.fileURL.scheme == "ox-model-input", let host = file.fileURL.host, let id = UUID(uuidString: host) else {
            throw RuntimeError.bridge("Provider attachment has not been verified by its native file owner")
        }
        return try groups.withLock { groups in
            guard let data = groups[id]?.bytes[file.fileURL] else {
                throw RuntimeError.bridge("Verified provider attachment scope has expired")
            }
            return data
        }
    }

    static func validate(_ messages: [Message]) throws {
        for message in messages {
            let content: [ContentBlock]
            switch message {
            case .user(let user): content = user.content
            case .assistant(let assistant): content = assistant.content
            case .toolResult(let result): content = result.content
            case .system: content = []
            }
            for block in content {
                if case .attachment(let file) = block { _ = try read(file) }
            }
        }
    }
}
