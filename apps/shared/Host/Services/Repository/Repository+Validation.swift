import CryptoKit
import Foundation
import Synchronization

extension Repository {
    static func writePackage(_ package: Package, at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(package)
        data.append(0x0A)
        try data.write(to: root.appendingPathComponent("repository.json"), options: .atomic)
    }

    private static let bundledContentHashes = Mutex<[URL: String]>([:])

    static func bundledContentHash(at root: URL, package: Package) throws -> String {
        if let hash = bundledContentHashes.withLock({ $0[root] }) { return hash }
        let startedAt = ContinuousClock.now
        let hash = try contentHash(at: root, package: package)
        bundledContentHashes.withLock { $0[root] = hash }
        Log.service.info("Repository.bundledContentHash services=\(package.services.count) skills=\(package.skills.count) ms=\(Int(startedAt.duration(to: .now) / .milliseconds(1)))")
        return hash
    }

    static func contentHash(at root: URL, package: Package) throws -> String {
        var digest = SHA256()
        let paths = package.services.map { $0.id.path } + package.skills.map { "skills/\($0)" }
        for path in paths.sorted() {
            let serviceRoot = root.appendingPathComponent(path, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: serviceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            var files: [(path: String, url: URL)] = []
            while let url = enumerator.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink != true, values.isRegularFile == true { files.append((path + "/" + url.pathComponents.suffix(enumerator.level).joined(separator: "/"), url)) }
            }
            for file in files.sorted(by: { $0.path < $1.path }) {
                digest.update(data: Data(file.path.utf8))
                digest.update(data: try Data(contentsOf: file.url))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validateService(_ service: Package.Service, root: URL) throws {
        let serviceRoot = root.appendingPathComponent(service.id.path, isDirectory: true)
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedServiceRoot = serviceRoot.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedServiceRoot.path.hasPrefix(resolvedRoot.path + "/") else {
            throw Failure(message: "Service path escapes the repository")
        }
        let manifestURL = serviceManifestURL(at: serviceRoot)
        try validateRegularFile(manifestURL, maximumSize: 512_000)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        let manifestID = service.id.kind == .mcp ? object?["id"] as? String : object?["domain"] as? String
        guard manifestID == service.id.runtimeID else {
            throw Failure(message: "Manifest identity mismatch for \(service.id.rawValue)")
        }
        if [.web, .api].contains(service.id.kind) {
            try validateRegularFile(serviceRoot.appendingPathComponent("actions.js"), maximumSize: 1_000_000)
        }
        let enumerator = FileManager.default.enumerator(
            at: serviceRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total = 0
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw Failure(message: "Symbolic links are not supported") }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            guard total <= 4_000_000 else { throw Failure(message: "Service \(service.id.rawValue) is too large") }
        }
    }

    static func validatePackageShape(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "name", "contentHash", "services", "skills"]),
              object["services"] is [String], object["skills"] is [String]
        else { throw Failure(message: "repository.json is invalid") }
    }

    static func validateRegularFile(_ url: URL, maximumSize: Int) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              (values.fileSize ?? 0) <= maximumSize else {
            throw Failure(message: "Invalid file \(url.lastPathComponent)")
        }
    }

    static func repositoryManifestURL(at root: URL) -> URL {
        let current = root.appendingPathComponent("repository.json")
        if FileManager.default.fileExists(atPath: current.path) { return current }
        return root.appendingPathComponent("ox.json")
    }

    static func serviceManifestURL(at root: URL) -> URL {
        let current = root.appendingPathComponent("service.json")
        if FileManager.default.fileExists(atPath: current.path) { return current }
        return root.appendingPathComponent("manifest.json")
    }
}
