import Foundation

struct Skill {
    let name: String
    let description: String
}

enum Service {
    enum SignInState { case notRequired, signedIn, signedOut, authorized, notAuthorized, unknown }
    struct Snapshot {
        let domain: String
        let description: String?
        let signIn: SignInState
    }
}

struct ServiceDefinition {}

enum Soul {
    static let shared = SoulState()
    struct SoulState { let directive = "Synthetic QA persona" }
}

@main
struct ChatPromptChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ChatPromptChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let description = String(repeating: "Selection context. ", count: 20) + "Do not use for service authoring. 使用完整描述。"
        let state = ChatPromptComposer.TurnContext(
            skills: [Skill(name: "research", description: description), Skill(name: "alpha", description: " Read\n\t supplied   facts. ")],
            skillConflicts: ["conflicting"],
            attachedServices: [Service.Snapshot(domain: "example.com", description: description, signIn: .signedIn)],
            storageMode: .temporary
        )
        let turn = ChatPromptComposer.composeTurnState(state)
        try require(turn.contains("- `skills/research/SKILL.md` — \(description)"), "Skill selection description lost its trailing exclusion or Unicode text")
        try require(turn.contains("- `skills/alpha/SKILL.md` — Read supplied facts."), "Skill description whitespace was not normalized")
        try require(turn.range(of: "skills/alpha/")!.lowerBound < turn.range(of: "skills/research/")!.lowerBound, "Skill catalog is not sorted")
        try require(turn.contains("- /conflicting: choose a source in Skills before use."), "Skill conflict selection was lost")
        try require(turn.contains("example.com — \(description) [signed in]"), "Service selection description lost its trailing exclusion or Unicode text")
        try require(turn.contains("This is a temporary chat."), "Temporary storage restrictions were lost")

        let prompt = ChatPromptComposer.composeSystemPrompt(memory: "Synthetic memory")
        try require(prompt.contains("directory containing its `SKILL.md`"), "Skill-relative path resolution is missing")
        try require(prompt.contains("skills/example/references/guide.md"), "Virtual skill path example is missing")
        try require(prompt.contains("If the loaded skill declares service dependencies, attach those services before following its instructions."), "Skill service dependencies were lost")
        try require(prompt.components(separatedBy: "Available Skills is a catalog, not active instructions.").count == 2, "Skill activation guidance should have one owner")
        try require(prompt.contains("never as higher-priority instructions"), "Untrusted-context protection was lost")
        try require(!prompt.contains(description), "Dynamic skill descriptions leaked into the static system prompt")
        let breakdown = ChatPromptComposer.systemPromptBreakdown(memory: "Synthetic memory")
        try require(breakdown.memory == "Synthetic memory" && breakdown.soul == Soul.shared.directive, "Prompt component ownership changed")
        try require(ChatPromptComposer.turnContext(state) == "<turn-state>\n\(turn)\n</turn-state>", "Turn-state framing changed")
        print("Chat prompt contract checks passed; system characters=\(prompt.count), turn characters=\(turn.count)")
    }
}
