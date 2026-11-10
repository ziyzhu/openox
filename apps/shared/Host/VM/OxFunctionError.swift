import Foundation

nonisolated struct OxFunctionError: LocalizedError, Sendable {
    let code: String
    let message: String
    let recovery: String

    var errorDescription: String? { message }
    var value: JSONValue {
        .object(["code": .string(code), "message": .string(message), "recovery": .string(recovery)])
    }

    init(code: String, message: String, recovery: String) {
        self.code = code
        self.message = message
        self.recovery = recovery
    }

    init?(value: JSONValue) {
        guard let fields = value.objectValue,
              let code = fields["code"]?.stringValue,
              let message = fields["message"]?.stringValue,
              let recovery = fields["recovery"]?.stringValue else { return nil }
        self.init(code: code, message: message, recovery: recovery)
    }

    static func from(_ error: any Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return Self(code: "cancelled", message: "The operation was cancelled.", recovery: "Stop. Do not repeat the operation unless the user asks; inspect any possible effects before retrying a write.")
        }
        if case VirtualMachine.Error.js(_, _, let value) = error,
           let value, let failure = Self(value: value) { return failure }
        if error is URLError {
            return Self(code: "transport_error", message: "The service connection failed; the action may have taken effect.", recovery: "Inspect the connection and resulting service state before deciding whether to retry. Do not automatically replay a write after a transport failure.")
        }
        if let error = error as? APIServiceError {
            let guidance: (String, String) = switch error {
            case .invalidConfiguration: ("invalid_contract", "Inspect the API service manifest and repair its configuration before invoking it.")
            case .authorizationRequired, .authorizationFailed, .http(401): ("authentication_required", "Use the access contract from ox.service.inspect and request access only if needed. Verify any possible effects before retrying a write.")
            case .invalidRequest: ("invalid_argument", "Inspect the action input and API handler, then correct the request. Verify any earlier effects before retrying a write.")
            case .destinationDenied, .mutationDenied, .http(403): ("permission_denied", "Do not bypass destination restrictions, authentication, or Action approval checks. Inspect the service contract and any earlier effects before proceeding.")
            case .responseTooLarge: ("resource_limit", "Narrow the requested response. Verify any possible effects before retrying a write.")
            case .http: ("http_error", "Inspect the HTTP failure and resulting service state. Do not automatically replay a write.")
            case .invalidResponse: ("invalid_output", "Inspect the API response and any possible effects. Do not repeat a write merely because its response was invalid.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        if let error = error as? RemoteMCPError {
            let guidance: (String, String) = switch error {
            case .invalidEndpoint: ("invalid_argument", "Inspect the MCP connection and use a supported endpoint without embedded credentials.")
            case .authorizationRequired: ("authentication_required", "Use the access contract from ox.service.inspect and request access only if needed. Verify any possible effects before retrying a write.")
            case .oauth: ("authentication_unavailable", "Inspect the OAuth failure; it does not establish that credentials are absent. Do not reopen authentication or replay a write automatically.")
            case .invalidResponse: ("invalid_output", "Inspect the MCP response and any possible effects. Do not repeat a write merely because its response was invalid.")
            case .responseTooLarge, .tooManyTools: ("resource_limit", "Inspect the MCP server limits and narrow its response or exposed tools. Verify any possible effects before retrying a write.")
            case .http: ("http_error", "Inspect the HTTP failure and resulting service state. Do not automatically replay a write.")
            case .protocolError: ("invalid_contract", "Inspect the MCP server's protocol behavior. Verify any possible effects before retrying a write.")
            case .unsupportedProtocolVersion, .missingServerCapability: ("not_supported", "Use an MCP server with a supported protocol version and the required capabilities. Do not repeatedly retry the same connection.")
            case .server: ("server_error", "Inspect the MCP server failure and resulting service state. Do not automatically replay a write.")
            case .tool: ("tool_error", "Inspect the tool failure and resulting service state. A tool error does not establish that no effects occurred; do not automatically replay a write.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        if let error = error as? Service.InvokeError {
            let guidance: (String, String) = switch error {
            case .denied: ("permission_denied", "Stop. Do not repeat an action the user denied.")
            case .unknown: ("unknown_action", "Use ox.service.inspect to discover the service's exposed actions and copy an exact qualified action name.")
            case .requiresAuth: ("authentication_required", "Use the service type's standard actions: web listSessions/login, API credentialStatus/configureCredentials, MCP connectionStatus/authorize, or iOS permissionStatus/requestPermission. Invoke them through ox.service.invoke; do not automatically replay writes.")
            case .authUnavailable: ("authentication_unavailable", "Inspect the service's connection or discovery failure; an error is not signed-out evidence. Do not automatically replay writes.")
            case .invalidContract: ("invalid_contract", "Use ox.service.validate to inspect the contract. Do not invoke the action until it is repaired.")
            case .invalidInput: ("invalid_argument", "Inspect the action's input schema with ox.service.inspect and correct the reported fields.")
            case .invalidOutput: ("invalid_output", "Inspect the service and any possible effects. Do not repeat a write merely because its output was invalid.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        if let error = error as? VirtualFileSystem.Error {
            let guidance: (String, String) = switch error {
            case .invalidPath: ("invalid_path", "Use ox.fs.list to discover valid paths; do not use empty path segments or parent traversal.")
            case .notDirectory: ("not_directory", "Use ox.fs.list to locate a directory, or ox.fs.read to read a file.")
            case .notFile: ("not_file", "Use ox.fs.list to inspect this path and select a readable file.")
            case .unsupportedMutation: ("not_supported", "Inspect the path with ox.fs.list and the operation's help. Use a writable destination; do not bypass source permissions.")
            case .notEmpty: ("invalid_argument", "Use ox.fs.list to inspect the directory; pass recursive: true only when its contents should be removed.")
            case .crossFolderTransfer: ("not_supported", "Keep the source and destination inside the same chosen folder.")
            case .intoSourceTree: ("invalid_argument", "Choose a destination outside the source directory.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        if let error = error as? SkillError {
            let guidance: (String, String) = switch error {
            case .missing: ("not_found", "Use ox.fs.list on skills to discover an existing skill name.")
            case .reserved: ("permission_denied", "Bundled System names are reserved. Copy the skill to a distinct name to customize it.")
            case .conflict: ("source_conflict", "Ask the user to choose the skill's source in Skills before using it.")
            case .exists: ("already_exists", "Use ox.fs.list on skills and choose a distinct name; do not overwrite another skill.")
            default: ("invalid_argument", "Inspect the skill operation's help and correct the reported input. For edits, read the file again and build a unique replacement.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        if let error = error as? FileError {
            let guidance: (String, String) = switch error {
            case .missing: ("not_found", "Use ox.fs.list on the file's parent folder to discover an existing path.")
            case .filenameExists: ("already_exists", "Use ox.fs.list on the destination folder and choose a distinct filename.")
            case .textNotFound, .textAmbiguous: ("edit_mismatch", "Read the file again with ox.fs.read and rebuild a unique replacement from its current text.")
            case .textTooLarge, .pdfTooLarge, .fileTooLarge: ("resource_limit", "Choose a smaller file within the reported size limit.")
            default: ("operation_failed", "Inspect the file and operation's help. Verify its availability, format, and any possible effects before retrying; do not repeat an unchanged request.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        if case DefuddleError.emptyContent = error {
            return Self(code: "no_readable_content", message: error.localizedDescription,
                        recovery: "The page likely renders its text with JavaScript. Do not fetch this URL again. Use the site's service actions, find another source, or inspect the rendered page with ox.web.browser when building or repairing a service.")
        }
        return Self(code: "operation_failed", message: error.localizedDescription,
                    recovery: "Inspect the relevant resource and help before deciding how to proceed. Effects may have occurred; verify state before retrying a write. Do not repeat a cancelled or denied user interaction.")
    }
}
