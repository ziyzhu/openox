import Foundation

nonisolated struct RenderedChatPrompt: Decodable, Sendable {
    let scaffold: String
    let soul: String
    let memory: String
    let rendered: String
}

nonisolated enum ChatPromptState {
    static func system(soul: String, memory: String) -> JSONValue {
        .object(["soul": .string(soul), "memory": .string(memory)])
    }

    static func turn(
        skills: [Skill],
        skillConflicts: [String],
        attachedServices: [Service.Snapshot],
        fileMountPaths: [String],
        artifactPaths: [String],
        isTemporary: Bool,
        responseLanguage: JSONValue
    ) -> JSONValue {
        .object([
            "skills": .array(skills.map { .object(["name": .string($0.name), "description": .string($0.description)]) }),
            "skillConflicts": .array(skillConflicts.map(JSONValue.string)),
            "attachedServices": .array(attachedServices.map { service in
                var fields: [String: JSONValue] = ["domain": .string(service.domain), "signIn": .string(signIn(service.signIn))]
                if let description = service.description { fields["description"] = .string(description) }
                return .object(fields)
            }),
            "fileMountPaths": .array(fileMountPaths.map(JSONValue.string)),
            "artifactPaths": .array(artifactPaths.map(JSONValue.string)),
            "storageMode": .string(isTemporary ? "temporary" : "persisted"),
            "responseLanguage": responseLanguage,
        ])
    }

    private static func signIn(_ state: Service.SignInState) -> String {
        switch state {
        case .notRequired: "notRequired"
        case .signedIn: "signedIn"
        case .signedOut: "signedOut"
        case .authorized: "authorized"
        case .notAuthorized: "notAuthorized"
        case .unknown: "unknown"
        }
    }
}
