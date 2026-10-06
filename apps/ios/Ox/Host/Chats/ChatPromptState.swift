import Foundation

nonisolated struct RenderedChatPrompt: Decodable, Sendable {
    let scaffold: String
    let soul: String
    let memory: String
    let rendered: String
}

nonisolated enum ChatPromptState {
    static func system(soul: String, memory: String, hostID: String, profileID: String) -> JSONValue {
        .object(["soul": .string(soul), "memory": .string(memory), "hostContext": hostContext(hostID: hostID, profileID: profileID)])
    }

    private static func hostContext(hostID: String, profileID: String) -> JSONValue {
        let scope: [String: JSONValue] = ["hostID": .string(hostID), "profileID": .string(profileID)]
        var host = scope
        host["functions"] = .array((OxFunctionCatalog.build().objectValue ?? [:]).keys.sorted().map(JSONValue.string))
        host["serviceKinds"] = .array(["web", "api", "ios", "mcp"].map(JSONValue.string))
        host["presentation"] = .string("chat-bubbles")
        host["externalFiles"] = .bool(true)
        return .object(["active": .object(scope), "hosts": .array([.object(host)])])
    }

    static func turn(
        skills: [Skill],
        skillConflicts: [String],
        attachedServices: [Service.Snapshot],
        fileMountPaths: [String],
        artifactPaths: [String],
        isTemporary: Bool,
        responseLanguage: JSONValue,
        hostID: String,
        profileID: String
    ) -> JSONValue {
        .object([
            "skills": .array(skills.map { .object(["name": .string($0.name), "description": .string($0.description)]) }),
            "skillConflicts": .array(skillConflicts.map(JSONValue.string)),
            "attachedServices": .array(attachedServices.map { service in
                var fields: [String: JSONValue] = ["domain": .string(service.domain), "signIn": .string(signIn(service.signIn))]
                if let description = service.description { fields["description"] = .string(description) }
                if service.domain == "ios:files" { fields["fileMounts"] = .array(fileMountPaths.map(JSONValue.string)) }
                return .object(fields)
            }),
            "hostContext": hostContext(hostID: hostID, profileID: profileID),
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
