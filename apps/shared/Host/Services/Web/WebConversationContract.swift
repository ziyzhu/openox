import Foundation

/// Shared website submission protocol. This does not change the service manifest format.
nonisolated enum WebConversationContract {
    static let actionID = "conversation"

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
