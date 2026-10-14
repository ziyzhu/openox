import Foundation

extension Conversation {
    public func appTheme(purpose: String) async throws -> JSONValue? {
        throw RuntimeError.bridge("This macOS Host has no client theme.")
    }

    public func setAppTheme(selection: String, purpose: String) async throws -> JSONValue? {
        throw RuntimeError.bridge("This macOS Host has no client theme.")
    }
}
