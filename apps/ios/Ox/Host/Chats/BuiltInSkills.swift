import Foundation

nonisolated enum BuiltInSkills {
    static let skills: [Skill] = {
        guard let root = Bundle.main.url(forResource: "SystemSkills", withExtension: "bundle") else {
            Log.app.error("BuiltInSkills.load missing bundle")
            return []
        }
        return SkillFiles.reservedNames.sorted().compactMap { name in
            do {
                var skill = try SkillFiles.load(directory: root.appendingPathComponent(name))
                guard skill.services.isEmpty else { throw SkillError.invalidPackage }
                skill.source = .system
                return skill
            } catch {
                Log.app.error("BuiltInSkills.load name=\(name) error=\(error.localizedDescription)")
                return nil
            }
        }
    }()
}
