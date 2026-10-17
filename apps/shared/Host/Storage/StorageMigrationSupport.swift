import Foundation
import CryptoKit
import Darwin

nonisolated enum StorageMigrationSupport {
    static func durableSourceDescriptor(_ path: String, at root: URL) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
        do {
            for (index, part) in parts.enumerated() {
                let next = openat(descriptor, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0))
                guard next >= 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
                Darwin.close(descriptor); descriptor = next
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0 else {
                throw StorageMigrationError.invalidApplicationStorage(path)
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }

    static func durableSourceFingerprint(_ path: String, at root: URL) throws -> String {
        let descriptor = try durableSourceDescriptor(path, at: root)
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
        var hash = SHA256()
        var size = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw StorageMigrationError.invalidApplicationStorage(path) }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
            size += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size, size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw StorageMigrationError.invalidApplicationStorage(path)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func migratedSkillName(domain: String, name: String) -> String {
        let known = ["xiaohongshu.com:research": "xiaohongshu-research", "www.1point3acres.com:research": "1point3acres-research", "news.ycombinator.com:display": "hacker-news-display", "x.com:research": "x-research", "amazon.com:product-research": "product-research"]
        return known[domain + ":" + name] ?? SkillFiles.slug(domain + "-" + name)
    }

    static func migratedSkillInstructions(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "skills/system:", with: "skills/")
            .replacingOccurrences(of: "ox.service.repository.", with: "ox.repository.")
            .replacingOccurrences(of: "ox.service.git.", with: "ox.repository.git.")
            .replacingOccurrences(of: "ox.app.serviceRepositories", with: "ox.app.repositories")
        let regex = try! NSRegularExpression(pattern: "skills/service:([a-z0-9.-]+):([a-z0-9-]+)/")
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let whole = Range(match.range, in: value), let domain = Range(match.range(at: 1), in: value), let name = Range(match.range(at: 2), in: value) else { continue }
            let replacement = "skills/" + migratedSkillName(domain: String(value[domain]), name: String(value[name])) + "/"
            value.replaceSubrange(whole, with: replacement)
        }
        return value
    }

    static func copyMigrationSource(from source: URL, to destination: URL) throws -> [String: String] {
        let inventory = try migrationSourceInventory(at: source)
        try FileManager.default.copyItem(at: source, to: destination)
        guard try migrationSourceInventory(at: source) == inventory,
              try migrationSourceInventory(at: destination) == inventory else {
            throw StorageMigrationError.collision(source.lastPathComponent)
        }
        return inventory
    }

    static func migrationSourceInventory(at root: URL) throws -> [String: String] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let values = try root.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(root.lastPathComponent) }
        if values.isRegularFile == true {
            return ["": try durableSourceFingerprint(root.lastPathComponent, at: root.deletingLastPathComponent())]
        }
        guard values.isDirectory == true else { throw StorageMigrationError.invalidApplicationStorage(root.lastPathComponent) }
        var files: [String: String] = [:]
        var directories = [(root, "")]
        while let (directory, prefix) = directories.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { throw StorageMigrationError.invalidApplicationStorage(url.lastPathComponent) }
                let path = prefix + url.lastPathComponent
                if values.isDirectory == true { directories.append((url, path + "/")) }
                else {
                    files[path] = try durableSourceFingerprint(path, at: root)
                }
            }
        }
        return files
    }

    static func providerIdentity(_ id: String, region: LLMRegion, modelID: String) -> String {
        if id == "amazon-bedrock" {
            return "amazon-bedrock:\(modelID.hasPrefix("claude") || modelID.hasPrefix("anthropic.") ? "messages" : "responses")"
        }
        let isRegional = ProviderRegistry.bundledDefinitions().contains { $0.legacyID == id && $0.legacyRegion != nil }
        return isRegional ? "\(id):\(region.rawValue)" : id
    }
}
