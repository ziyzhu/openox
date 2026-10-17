import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin

extension ProfileMigrator {
    static func migrateProfileSkillCatalog(at root: URL) throws {
        let manager = FileManager.default
        let skills = root.appendingPathComponent("skills")
        if manager.fileExists(atPath: skills.path) {
            for directory in try manager.contentsOfDirectory(at: skills, includingPropertiesForKeys: nil) where SkillFiles.isLocalName(directory.lastPathComponent) {
                var skill = try SkillFiles.load(directory: directory)
                skill.instructions = StorageMigrationSupport.migratedSkillInstructions(skill.instructions)
                var destination = directory
                if ["import-memory", "manage-artifacts", "manage-services", "manage-skills"].contains(skill.name) {
                    skill.name = "user-" + skill.name
                    destination = skills.appendingPathComponent(skill.name)
                    if manager.fileExists(atPath: destination.path), try SkillFiles.load(directory: destination) != skill {
                        throw StorageMigrationError.collision(destination.lastPathComponent)
                    }
                }
                try SkillFiles.write(skill, directory: destination)
                if destination != directory { try manager.removeItem(at: directory) }
            }
        }
        let selections = root.appendingPathComponent("skill-selections.json")
        if manager.fileExists(atPath: selections.path) {
            guard try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: selections)).version == 1 else { throw SkillError.invalidPackage }
        }
    }

    static func migrateReservedImportMemorySkill(at root: URL) throws {
        try migrateReservedSkill("import-memory", at: root)
    }

    static func migrateReservedOutcomeSkills(at root: URL) throws {
        for name in ["evolve", "visualize"] {
            try migrateReservedSkill(name, at: root)
        }
    }

    static func migrateReservedSkill(_ name: String, at root: URL) throws {
        let manager = FileManager.default
        let source = root.appendingPathComponent("skills/\(name)", isDirectory: true)
        let destination = root.appendingPathComponent("skills/user-\(name)", isDirectory: true)
        let sourceExists = manager.fileExists(atPath: source.path)
        let destinationExists = manager.fileExists(atPath: destination.path)
        if sourceExists {
            var skill = try SkillFiles.load(directory: source)
            skill.name = "user-\(name)"
            if destinationExists {
                guard try SkillFiles.load(directory: destination) == skill else {
                    throw StorageMigrationError.collision("skills/user-\(name)")
                }
            } else {
                try SkillFiles.write(skill, directory: destination)
            }
        }
        let selectionsFile = root.appendingPathComponent("skill-selections.json")
        if manager.fileExists(atPath: selectionsFile.path) {
            var selections = try JSONDecoder().decode(SkillSelections.self, from: Data(contentsOf: selectionsFile))
            guard selections.version == 1 else { throw SkillError.invalidPackage }
            if selections.sources[name] == "user", sourceExists || destinationExists {
                guard selections.sources["user-\(name)"].map({ $0 == "user" }) ?? true else {
                    throw StorageMigrationError.collision("skill-selections.json:user-\(name)")
                }
                selections.sources["user-\(name)"] = "user"
                selections.sources.removeValue(forKey: name)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(selections).write(to: selectionsFile, options: .atomic)
            }
        }
        if sourceExists { try manager.removeItem(at: source) }
        Log.app.info("StorageMigrator.reservedSkill name=\(name) renamed=\(sourceExists)")
    }

    static func migrateLegacySkills(at root: URL) throws {
        let legacy = root.appendingPathComponent("COMMANDS.md")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let text = try String(contentsOf: legacy, encoding: .utf8)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        var existing = Set(try manager.contentsOfDirectory(atPath: skillsRoot.path))
        var claimed: Set<String> = []
        var migrated = 0
        for legacySkill in parseLegacySkills(text) {
            let base = SkillFiles.slug(legacySkill.name)
            guard !base.isEmpty else { continue }
            var suffix = 1
            while true {
                let name = suffix == 1 ? base : "\(base)-\(suffix)"
                suffix += 1
                guard !claimed.contains(name) else { continue }
                let description = legacySkill.instructions
                    .split(whereSeparator: \.isNewline)
                    .first
                    .map(String.init) ?? name
                let skill = Skill(
                    name: name,
                    description: description,
                    instructions: legacySkill.instructions,
                    services: legacySkill.services
                )
                let directory = skillsRoot.appendingPathComponent(name, isDirectory: true)
                let file = directory.appendingPathComponent(SkillFiles.fileName)
                if existing.contains(name) {
                    guard let current = try? String(contentsOf: file, encoding: .utf8),
                          SkillFiles.parse(current, directoryName: name) == skill else { continue }
                } else {
                    let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                    defer { FileStaging.cleanup(staging, operation: "legacy-skill-migration") }
                    try SkillFiles.serialize(skill).write(
                        to: staging.appendingPathComponent(SkillFiles.fileName),
                        atomically: true,
                        encoding: .utf8
                    )
                    try manager.moveItem(at: staging, to: directory)
                    existing.insert(name)
                }
                claimed.insert(name)
                migrated += 1
                break
            }
        }
        try manager.removeItem(at: legacy)
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.commandsToSkills root=\(root.lastPathComponent) count=\(migrated)")
    }

    static func namespaceUserSkills(at root: URL) throws {
        let namespace = "profile"
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: skillsRoot.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var migrated = 0
        for source in directories {
            guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  !source.lastPathComponent.hasPrefix("."),
                  !source.lastPathComponent.hasPrefix("\(namespace):"),
                  let localName = legacySkillLocalName(source.lastPathComponent, namespace: namespace),
                  let text = try? String(
                    contentsOf: source.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: source.lastPathComponent) else { continue }
            let destinationName = "\(namespace):\(localName)"
            let migratedSkill = Skill(
                name: destinationName,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services
            )
            let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
            let destinationFile = destination.appendingPathComponent(SkillFiles.fileName)
            if manager.fileExists(atPath: destination.path) {
                guard let existing = try? String(contentsOf: destinationFile, encoding: .utf8),
                      SkillFiles.parse(existing, directoryName: destinationName) == migratedSkill else {
                    throw StorageMigrationError.collision(destination.path)
                }
            } else {
                let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                defer { FileStaging.cleanup(staging, operation: "skill-namespace-migration") }
                try SkillFiles.serialize(migratedSkill).write(
                    to: staging.appendingPathComponent(SkillFiles.fileName),
                    atomically: true,
                    encoding: .utf8
                )
                try manager.moveItem(at: staging, to: destination)
            }
            try manager.removeItem(at: source)
            migrated += 1
        }
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.namespaceUserSkills root=\(root.lastPathComponent) count=\(migrated)")
    }

    private static func legacySkillLocalName(_ name: String, namespace: String) -> String? {
        if SkillFiles.isLocalName(name) { return name }
        let parts = name
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2,
              !["system", "service", namespace].contains(parts[0]),
              SkillFiles.isLocalName(parts[0]),
              SkillFiles.isLocalName(parts[1]) else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    private static func parseLegacySkills(_ text: String) -> [Skill] {
        var skills: [Skill] = []
        var name: String?
        var services: [String] = []
        var body: [Substring] = []
        func flush() {
            guard let name, !name.isEmpty else { return }
            let instructions = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            skills.append(Skill(
                name: name,
                description: instructions,
                instructions: instructions,
                services: services
            ))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                flush()
                name = String(line.dropFirst(3))
                services = []
                body = []
            } else if name != nil {
                if body.isEmpty, services.isEmpty, line.hasPrefix("services:") {
                    services = line.dropFirst("services:".count)
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else {
                    body.append(line)
                }
            }
        }
        flush()
        return skills
    }

    static func removeUserSkillNamespace(at root: URL) throws {
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let manager = FileManager.default
        guard manager.fileExists(atPath: skillsRoot.path) else { return }
        let directories = try manager.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var migrated = 0
        for source in directories {
            let sourceName = source.lastPathComponent
            let prefix = "profile:"
            guard (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  sourceName.hasPrefix(prefix),
                  SkillFiles.isUserName(String(sourceName.dropFirst(prefix.count))),
                  let text = try? String(
                    contentsOf: source.appendingPathComponent(SkillFiles.fileName),
                    encoding: .utf8
                  ),
                  let skill = SkillFiles.parse(text, directoryName: sourceName) else { continue }
            let destinationName = String(sourceName.dropFirst(prefix.count))
            let migratedSkill = Skill(
                name: destinationName,
                description: skill.description,
                instructions: skill.instructions,
                services: skill.services
            )
            let destination = skillsRoot.appendingPathComponent(destinationName, isDirectory: true)
            let destinationFile = destination.appendingPathComponent(SkillFiles.fileName)
            if manager.fileExists(atPath: destination.path) {
                guard let existing = try? String(contentsOf: destinationFile, encoding: .utf8),
                      SkillFiles.parse(existing, directoryName: destinationName) == migratedSkill else {
                    throw StorageMigrationError.collision(destination.path)
                }
            } else {
                let staging = try FileStaging.createDirectory(in: skillsRoot, prefix: "migration")
                defer { FileStaging.cleanup(staging, operation: "plain-skill-name-migration") }
                try SkillFiles.serialize(migratedSkill).write(
                    to: staging.appendingPathComponent(SkillFiles.fileName),
                    atomically: true,
                    encoding: .utf8
                )
                try manager.moveItem(at: staging, to: destination)
            }
            try manager.removeItem(at: source)
            migrated += 1
        }
        guard migrated > 0 else { return }
        Log.app.info("StorageMigrator.removeUserSkillNamespace root=\(root.lastPathComponent) count=\(migrated)")
    }
}
