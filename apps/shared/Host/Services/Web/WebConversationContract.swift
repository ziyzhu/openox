import Foundation

/// Shared website submission protocol. This does not change the service manifest format.
nonisolated enum WebConversationContract {
    static let actionID = "conversation"

    static func validate(_ actions: [Manifest.Action], definitions: [String: JSONValue], isWeb: Bool) throws {
        guard let action = actions.first(where: { $0.id == actionID }) else { return }
        guard isWeb, !action.blocking,
              !(action.raw["baseUrl"]?.stringValue?.contains(where: { $0 == "{" || $0 == "}" }) ?? false) else {
            throw ServiceDefinition.ValidationError.invalid("standard conversation Action")
        }
        for candidate in actions where [actionID, ModelServiceContract.list].contains(candidate.id) {
            guard let expected = ModelServiceContract.schemas[candidate.id]?.objectValue,
                  try ModelServiceContract.normalized(candidate.inputSchema ?? .null, definitions: definitions) == ModelServiceContract.normalized(expected["inputSchema"] ?? .null),
                  try ModelServiceContract.normalized(candidate.outputSchema ?? .null, definitions: definitions) == ModelServiceContract.normalized(expected["outputSchema"] ?? .null) else {
                throw ServiceDefinition.ValidationError.invalid("standard website Action \(candidate.id)")
            }
        }
    }

    static func validateInput(_ args: JSONValue, service: ServiceDefinition) throws {
        guard let action = service.action(actionID), let schema = action.inputSchema else {
            throw Service.InvokeError.unknown(service.qualifiedActionName(actionID))
        }
        let errors = JSONSchemaValidator.validate(args, against: schema, definitions: service.definitions)
        guard errors.isEmpty else { throw Service.InvokeError.invalidInput(service.qualifiedActionName(actionID), errors) }
    }

    static func requiresApproval(_ args: JSONValue) -> Bool {
        args.objectValue?["operation"]?.stringValue == "submit"
    }
}
