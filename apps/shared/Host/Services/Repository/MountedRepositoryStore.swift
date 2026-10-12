import Foundation

nonisolated struct MountedRepositoryStore {
    struct Record: Codable, Sendable {
        let id: String
        let grantID: String
        let relativePath: [String]
        var isEnabled: Bool
    }

    private struct Document: Codable {
        let version: Int
        var repositories: [Record]
    }

    private let fileURL = AppStoragePaths.mountedRepositories
    private var document: Result<Document, Error>

    init() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 512_000 else { throw RuntimeError.bridge("Mounted repository settings are too large") }
                let decoded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: fileURL))
                let ids = decoded.repositories.compactMap { UUID(uuidString: $0.id) }
                guard decoded.version == 1, decoded.repositories.count <= 256,
                      ids.count == decoded.repositories.count, Set(ids).count == ids.count else {
                    throw RuntimeError.bridge("Unsupported mounted repository settings; use the version that last saved them or a newer build")
                }
                document = .success(decoded)
            } else {
                document = .success(Document(version: 1, repositories: []))
            }
        } catch {
            document = .failure(error)
            Log.service.error("MountedRepositories settings unavailable error=\(error.localizedDescription)")
        }
    }

    func records() throws -> [Record] { try document.get().repositories }

    mutating func connect(grantID: String, relativePath: [String]) throws -> Record {
        var updated = try document.get()
        if let existing = updated.repositories.first(where: { $0.grantID == grantID && $0.relativePath == relativePath }) { return existing }
        guard updated.repositories.count < 256 else { throw RuntimeError.bridge("Mounted repository limit reached") }
        let record = Record(id: UUID().uuidString.lowercased(), grantID: grantID, relativePath: relativePath, isEnabled: true)
        updated.repositories.append(record)
        try save(updated)
        return record
    }

    mutating func disconnect(_ id: String) throws {
        var updated = try document.get()
        guard updated.repositories.contains(where: { $0.id == id }) else { throw RuntimeError.bridge("Unknown mounted repository") }
        updated.repositories.removeAll { $0.id == id }
        try save(updated)
    }

    mutating func setEnabled(_ id: String, enabled: Bool) throws {
        var updated = try document.get()
        guard let index = updated.repositories.firstIndex(where: { $0.id == id }) else { throw RuntimeError.bridge("Unknown mounted repository") }
        updated.repositories[index].isEnabled = enabled
        try save(updated)
    }

    private mutating func save(_ updated: Document) throws {
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        document = .success(updated)
        Log.service.info("MountedRepositories saved count=\(updated.repositories.count)")
    }
}
