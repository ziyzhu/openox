import Foundation

extension SkillFiles {
    nonisolated static func isResourcePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count >= 2 && ["references", "scripts"].contains(parts[0])
            && parts.dropFirst().allSatisfy { $0.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]*$", options: .regularExpression) != nil }
            && (parts[0] != "scripts" || path.hasSuffix(".js"))
    }

    nonisolated static func load(directory: URL) throws -> Skill {
        let manager = FileManager.default
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard try directory.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              values.isDirectory == true, values.isSymbolicLink != true else { throw SkillError.invalidPackage }
        var files: [String: String] = [:]
        var total = 0
        let root = directory.standardizedFileURL.path + "/"
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else {
            throw SkillError.invalidPackage
        }
        while let url = enumerator.nextObject() as? URL {
            let path = String(url.standardizedFileURL.path.dropFirst(root.count))
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isSymbolicLink != true else { throw SkillError.invalidPackage }
            if info.isDirectory == true {
                guard ["references", "scripts"].contains(path) || isResourcePath(path + "/file.js") else { throw SkillError.invalidPackage }
                continue
            }
            guard info.isRegularFile == true, path == fileName || isResourcePath(path) else { throw SkillError.invalidPackage }
            total += info.fileSize ?? 0
            guard total <= maximumBytes, files.count < maximumFiles else { throw SkillError.invalidPackage }
            files[path] = try String(contentsOf: url, encoding: .utf8)
        }
        guard let text = files.removeValue(forKey: fileName), var skill = parse(text, directoryName: directory.lastPathComponent) else {
            throw SkillError.invalidPackage
        }
        skill.resources = files.isEmpty ? nil : files
        return skill
    }

    nonisolated static func validate(_ skill: Skill) throws {
        guard isLocalName(skill.name), parse(serialize(skill), directoryName: skill.name) != nil else { throw SkillError.invalidPackage }
        let resources = skill.resources ?? [:]
        guard resources.keys.allSatisfy(isResourcePath), resources.count < maximumFiles,
              !resources.keys.contains(where: { path in resources.keys.contains { $0.hasPrefix(path + "/") } }),
              resources.values.reduce(serialize(skill).utf8.count, { $0 + $1.utf8.count }) <= maximumBytes else { throw SkillError.invalidPackage }
    }

    nonisolated static func write(_ skill: Skill, directory: URL) throws {
        try validate(skill)
        let manager = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkillError.invalidPackage }
        let staging = parent.appendingPathComponent(".skill-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        var files = skill.resources ?? [:]
        files[fileName] = serialize(skill)
        for (path, content) in files {
            let file = staging.appendingPathComponent(path)
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        if manager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard try directory.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              values.isDirectory == true, values.isSymbolicLink != true else { throw SkillError.invalidPackage }
            _ = try manager.replaceItemAt(directory, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: directory)
        }
    }
}
