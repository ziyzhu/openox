import Foundation

extension ProfileMigrator {
    static func migrateResponsePreferences(at root: URL) throws {
        let manager = FileManager.default
        let source = root.appendingPathComponent("SOUL.md")
        guard manager.fileExists(atPath: source.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try source.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= FileLimits.textBytes else {
            throw StorageMigrationError.invalidApplicationStorage("Legacy voice preferences are not a readable text file")
        }
        let original = try Data(contentsOf: source)
        guard let text = String(data: original, encoding: .utf8) else {
            throw StorageMigrationError.invalidApplicationStorage("Legacy voice preferences are not UTF-8")
        }
        let archive = ProfileIO.portableStateDirectory(root).appendingPathComponent("legacy-soul.md")
        if manager.fileExists(atPath: archive.path) {
            let archived = try archive.resourceValues(forKeys: keys)
            guard archived.isRegularFile == true, archived.isSymbolicLink != true, archived.fileSize == original.count,
                  try Data(contentsOf: archive) == original else {
                throw StorageMigrationError.invalidApplicationStorage("Legacy voice backup differs from the source")
            }
        } else {
            try original.write(to: archive, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: archive)
            try handle.synchronize()
            try handle.close()
            try syncDurableDirectory(archive.deletingLastPathComponent())
        }
        let preferences = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousDefault = "## Voice\nBe warm, quietly competent, and a little dry. Sound like a capable teammate in a live conversation. Lead with the result, default to concise natural replies, and be direct about risks or disagreement. Match the user's tone and use judgment; style never overrides accuracy, safety, or the user's request."
        var migrated = false
        if !preferences.isEmpty, preferences != previousDefault {
            let destination = root.appendingPathComponent("MEMORY.md")
            let existing: Data
            if manager.fileExists(atPath: destination.path) {
                let memory = try destination.resourceValues(forKeys: keys)
                guard memory.isRegularFile == true, memory.isSymbolicLink != true,
                      let size = memory.fileSize, size <= 512 * 1024 else {
                    throw StorageMigrationError.invalidApplicationStorage("Memory is not a readable text file")
                }
                existing = try Data(contentsOf: destination)
            } else {
                existing = Data()
            }
            guard let memory = String(data: existing, encoding: .utf8) else {
                throw StorageMigrationError.invalidApplicationStorage("Memory is not UTF-8")
            }
            let section = "## Response preferences\n\nThe user's saved response preferences:\n\n" + preferences
            if !memory.contains(section) {
                let separator = memory.isEmpty ? "" : memory.hasSuffix("\n") ? "\n" : "\n\n"
                let updated = Data((memory + separator + section + "\n").utf8)
                guard updated.count <= 512 * 1024 else {
                    throw StorageMigrationError.invalidApplicationStorage("Memory and legacy voice preferences exceed the text limit; original files and backup are preserved")
                }
                if manager.fileExists(atPath: destination.path), try Data(contentsOf: destination) != existing {
                    throw StorageMigrationError.invalidApplicationStorage("Memory changed during voice migration; retry preparation")
                }
                try updated.write(to: destination, options: .atomic)
                let handle = try FileHandle(forWritingTo: destination)
                try handle.synchronize()
                try handle.close()
                try syncDurableDirectory(root)
            }
            migrated = true
        }
        guard try Data(contentsOf: source) == original else {
            throw StorageMigrationError.invalidApplicationStorage("Legacy voice preferences changed during migration")
        }
        try manager.removeItem(at: source)
        try syncDurableDirectory(root)
        Log.app.info("StorageMigrator.responsePreferences migrated=\(migrated) bytes=\(original.count) sourceArchived=true")
    }
}
