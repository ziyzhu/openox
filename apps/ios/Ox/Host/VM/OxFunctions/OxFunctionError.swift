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
        if error is CancellationError {
            return Self(code: "cancelled", message: "The operation was cancelled.", recovery: "Stop. Do not repeat the operation unless the user asks; inspect any possible effects before retrying a write.")
        }
        if let error = error as? Service.InvokeError {
            let guidance: (String, String) = switch error {
            case .denied: ("permission_denied", "Stop. Do not repeat an action the user denied.")
            case .unknown: ("unknown_action", "Use ox.service.inspect to discover the service's exposed actions and copy an exact qualified action name.")
            case .requiresAuth: ("authentication_required", "Ask the user to sign in through ox.service.signIn before trying the action again.")
            case .authUnavailable: ("authentication_unavailable", "Wait until the service is available, then inspect its sign-in state before retrying.")
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
        if let error = error as? ArtifactError {
            let guidance: (String, String) = switch error {
            case .missing: ("not_found", "Use ox.fs.list on the file's parent folder to discover an existing path.")
            case .filenameExists: ("already_exists", "Use ox.fs.list on the destination folder and choose a distinct filename.")
            case .textNotFound, .textAmbiguous: ("edit_mismatch", "Read the file again with ox.fs.read and rebuild a unique replacement from its current text.")
            case .textTooLarge, .pdfTooLarge, .fileTooLarge: ("resource_limit", "Choose a smaller file within the reported size limit.")
            default: ("operation_failed", "Inspect the file and operation's help. Verify its availability, format, and any possible effects before retrying; do not repeat an unchanged request.")
            }
            return Self(code: guidance.0, message: error.localizedDescription, recovery: guidance.1)
        }
        return Self(code: "operation_failed", message: error.localizedDescription,
                    recovery: "Inspect the relevant resource and help before deciding how to proceed. Effects may have occurred; verify state before retrying a write. Do not repeat a cancelled or denied user interaction.")
    }
}
