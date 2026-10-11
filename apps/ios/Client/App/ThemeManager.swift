import SwiftUI

@MainActor @Observable final class ThemeManager {
    static let shared = ThemeManager()

    private static let key = "app.theme"
    private static let sharedDefaults = UserDefaults(suiteName: AppStoragePaths.appGroupIdentifier)

    var theme: AppTheme {
        didSet {
            guard oldValue != theme else { return }
            let updatedTheme = theme
            AppTheme.current = updatedTheme
            Self.sharedDefaults?.set(updatedTheme.rawValue, forKey: Self.key)
            Log.app.info("Theme.select theme=\(updatedTheme.rawValue)")
        }
    }

    private init() {
        let sharedValue = Self.sharedDefaults?.string(forKey: Self.key)
        let stored = sharedValue.flatMap(AppTheme.init(rawValue:)) ?? .creatorPick
        theme = stored
        AppTheme.current = stored
        if Self.sharedDefaults != nil {
            Log.app.info("Theme.restore theme=\(stored.rawValue) source=shared")
        } else {
            Log.app.error("Theme.restore app-group unavailable")
        }
    }
}

extension View {
    func themed() -> some View { modifier(ThemedModifier()) }
}

private struct ThemedModifier: ViewModifier {
    @State private var manager = ThemeManager.shared

    func body(content: Content) -> some View {
        content
            .environment(\.appTheme, manager.theme)
            .preferredColorScheme(manager.theme.colorScheme)
    }
}
