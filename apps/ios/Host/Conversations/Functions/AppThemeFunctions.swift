import Foundation

extension Conversation {
    public func appTheme(purpose: String) async throws -> JSONValue? {
        return try await tracked(Actions.appTheme, .object([:]), purpose: purpose) {
            let theme = ThemeManager.shared.theme
            return .object([
                "selection": .string(theme.rawValue),
                "appearance": .string(theme == .dark ? "dark" : "light"),
            ])
        }
    }

    public func setAppTheme(selection: String, purpose: String) async throws -> JSONValue? {
        guard let theme = AppTheme(rawValue: selection) else {
            throw RuntimeError.bridge("ox.app.setTheme: selection must be creatorPick, light, or dark")
        }
        return try await tracked(Actions.appSetTheme, .object(["selection": .string(selection)]), purpose: purpose) {
            try Task.checkCancellation()
            let manager = ThemeManager.shared
            let changed = manager.theme != theme
            manager.theme = theme
            Log.app.info("bridge.app.setTheme selection=\(selection) changed=\(changed)")
            return .object([
                "selection": .string(manager.theme.rawValue),
                "appearance": .string(manager.theme == .dark ? "dark" : "light"),
                "changed": .bool(changed),
            ])
        }
    }
}
