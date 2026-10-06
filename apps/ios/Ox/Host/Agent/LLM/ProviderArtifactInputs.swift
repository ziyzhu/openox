import Foundation
import Synchronization

nonisolated final class ProviderArtifactInputs: Sendable {
    nonisolated private struct Group: Sendable {
        var sources: [URL: Artifact] = [:]
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

    func snapshot(_ artifact: Artifact, data: Data) throws -> Artifact {
        try Self.groups.withLock { groups in
            guard var group = groups[id] else { throw RuntimeError.bridge("Provider artifact input scope is closed") }
            if let existing = group.sources[artifact.fileURL] {
                guard group.bytes[existing.fileURL] == data else { throw RuntimeError.bridge("Immutable artifact changed during model input preparation") }
                return existing
            }
            guard data.count <= ArtifactLimits.fileBytes, group.size + data.count <= 4 * ArtifactLimits.fileBytes else {
                throw RuntimeError.bridge("Verified provider artifact inputs exceed their bounded memory budget")
            }
            let directory = URL(string: "ox-model-input://\(id.uuidString)/\(UUID().uuidString)/")!
            let snapshot = Artifact(fileName: artifact.fileName, directory: directory, size: data.count)
            group.sources[artifact.fileURL] = snapshot
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

    func cached(_ artifact: Artifact) -> Artifact? {
        Self.groups.withLock { $0[id]?.sources[artifact.fileURL] }
    }

    static func read(_ artifact: Artifact) throws -> Data {
        guard artifact.fileURL.scheme == "ox-model-input", let host = artifact.fileURL.host, let id = UUID(uuidString: host) else {
            throw RuntimeError.bridge("Provider attachment has not been verified by its native artifact owner")
        }
        return try groups.withLock { groups in
            guard let data = groups[id]?.bytes[artifact.fileURL] else {
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
            }
            for block in content {
                if case .attachment(let artifact) = block { _ = try read(artifact) }
            }
        }
    }
}
