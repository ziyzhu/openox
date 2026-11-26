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

    static func serviceContentHash(at root: URL, service: Package.Service, provenance: Descriptor.Provenance) throws -> String {
        let cacheKey = root.appendingPathComponent(service.id.path)
        if provenance == .bundled, let hash = bundledContentHashes.withLock({ $0[cacheKey] }) { return hash }
        let hash = try contentHash(at: root, paths: [service.id.path], options: [])
        if provenance == .bundled { bundledContentHashes.withLock { $0[cacheKey] = hash } }
        return hash
    }

    static func contentHash(at root: URL, package: Package) throws -> String {
        try contentHash(at: root, paths: package.services.map { $0.id.path } + package.skills.map { "skills/\($0)" })
    }

    private static func contentHash(at root: URL, paths: [String], options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]) throws -> String {
        var digest = SHA256()
        for path in paths.sorted() {
            var files: [(path: String, url: URL)] = []
            guard try forEachFile(in: root.appendingPathComponent(path, isDirectory: true), options: options, { url, values, relative in
                if values.isSymbolicLink != true, values.isRegularFile == true { files.append((path + "/" + relative, url)) }
                return true
            }) else { throw Failure(message: "Source directory is unavailable: \(path)") }
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
        var total = 0
        try forEachFile(in: serviceRoot) { _, values, _ in
            guard values.isSymbolicLink != true else { throw Failure(message: "Symbolic links are not supported") }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            guard total <= 4_000_000 else { throw Failure(message: "Service \(service.id.rawValue) is too large") }
            return true
        }
    }

    @discardableResult
    static func forEachFile(
        in root: URL,
        options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles],
        _ visit: (_ url: URL, _ values: URLResourceValues, _ relativePath: String) throws -> Bool
    ) throws -> Bool {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { _, error in
            failure = error
            return false
        }) else { return false }
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard try visit(url, values, url.pathComponents.suffix(enumerator.level).joined(separator: "/")) else { break }
        }
        if let failure { throw failure }
        return true
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
