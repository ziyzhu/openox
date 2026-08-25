import Foundation

nonisolated enum BuiltInSkills {
    struct Reference: Sendable {
        let name: String
        let content: String
    }

    struct Entry: Sendable {
        let name: String
        let description: String
        let content: String
        let references: [Reference]
    }

    static let all = load()

    static func entry(named name: String) -> Entry? {
        all.first { $0.name == name }
    }

    static func isReferenceName(_ name: String) -> Bool {
        guard name.hasSuffix(".md") else { return false }
        return SkillFiles.isLocalName(String(name.dropLast(3)))
    }

    private static func load() -> [Entry] {
        guard let root = Bundle.main.url(forResource: "SystemSkills", withExtension: "bundle") else {
            Log.app.error("BuiltInSkills.load missing bundle resources")
            return []
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        } catch {
            Log.app.error("BuiltInSkills.load root=SystemSkills.bundle failed=\(error.localizedDescription)")
            return []
        }
        let entries = names.compactMap { load(name: $0, root: root) }
        Log.app.info("BuiltInSkills.load count=\(entries.count)")
        return entries
    }

    private static func load(name: String, root: URL) -> Entry? {
        guard SkillFiles.isLocalName(name) else {
            Log.app.error("BuiltInSkills.load invalid-name=\(name)")
            return nil
        }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let url = directory.appendingPathComponent(SkillFiles.fileName)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard var skill = SkillFiles.parse(text, directoryName: name), skill.services.isEmpty else {
                Log.app.error("BuiltInSkills.load invalid-skill=\(name)")
                return nil
            }
            skill.name = "system:\(name)"
            return Entry(
                name: skill.name,
                description: skill.description,
                content: SkillFiles.serialize(skill),
                references: loadReferences(skill: name, directory: directory)
            )
        } catch {
            Log.app.error("BuiltInSkills.load name=\(name) failed=\(error.localizedDescription)")
            return nil
        }
    }

    private static func loadReferences(skill name: String, directory: URL) -> [Reference] {
        let root = directory.appendingPathComponent("references", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        do {
            return try FileManager.default
                .contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url in
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          isReferenceName(url.lastPathComponent) else {
                        Log.app.error("BuiltInSkills.load invalid-reference skill=\(name) name=\(url.lastPathComponent)")
                        return nil
                    }
                    return Reference(
                        name: url.lastPathComponent,
                        content: try String(contentsOf: url, encoding: .utf8)
                    )
                }
        } catch {
            Log.app.error("BuiltInSkills.load references skill=\(name) failed=\(error.localizedDescription)")
            return []
        }
    }
}
