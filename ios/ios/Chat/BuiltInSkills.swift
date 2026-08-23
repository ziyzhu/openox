import Foundation

nonisolated enum BuiltInSkills {
    struct Entry: Sendable {
        let name: String
        let description: String
        let content: String
    }

    static let all = load()

    static func entry(named name: String) -> Entry? {
        all.first { $0.name == name }
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
        let url = root
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(SkillFiles.fileName)
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
                content: SkillFiles.serialize(skill)
            )
        } catch {
            Log.app.error("BuiltInSkills.load name=\(name) failed=\(error.localizedDescription)")
            return nil
        }
    }
}
