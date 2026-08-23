import Foundation
import Observation

@MainActor
@Observable
final class AppLocale {
    static let shared = AppLocale()

    enum Language: String, CaseIterable, Codable {
        case system
        case english = "en"
        case simplifiedChinese = "zh-Hans"

        var displayName: String {
            switch self {
            case .system: return L10n.string("System", comment: "")
            case .english: return "English"
            case .simplifiedChinese: return "简体中文"
            }
        }
    }

    var language: Language {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.key)
            Log.app.info("AppLocale.language -> \(language.rawValue)")
        }
    }

    nonisolated private static let key = "app.language"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.key)
        self.language = stored.flatMap(Language.init(rawValue:)) ?? .system
        Log.app.info("AppLocale ready language=\(self.language.rawValue) locale=\(self.locale.identifier)")
    }

    nonisolated static var resolvedLocale: Locale {
        guard let stored = UserDefaults.standard.string(forKey: key), stored != Language.system.rawValue else {
            return .current
        }
        return Locale(identifier: stored)
    }

    var locale: Locale {
        switch language {
        case .system: return .current
        case .english, .simplifiedChinese: return Locale(identifier: language.rawValue)
        }
    }

    func serviceLocale(for region: LLMRegion) -> String? {
        if language == .system, region == .china {
            return "zh-Hans"
        }
        guard let code = locale.language.languageCode?.identifier, code != "en" else { return nil }
        return code == "zh" ? "zh-Hans" : locale.identifier
    }

    var responseDirective: String {
        Self.responseDirective(for: locale)
    }

    nonisolated static var resolvedResponseDirective: String {
        responseDirective(for: resolvedLocale)
    }

    nonisolated private static func responseDirective(for resolved: Locale) -> String {
        guard let code = resolved.language.languageCode?.identifier, code != "en" else {
            return ""
        }
        let name = Locale(identifier: "en").localizedString(forIdentifier: resolved.identifier) ?? resolved.identifier
        return """
        ## Language
        Always reply in \(name) (\(resolved.identifier)), no matter what language the user writes in, unless they explicitly ask for another language. Write every word of every reply — prose, lists, labels — in \(name), and use local conventions for dates, numbers, and currency.
        """
    }
}

nonisolated enum L10n {
    static func string(_ value: String.LocalizationValue, comment: StaticString = "") -> String {
        String(localized: LocalizedStringResource(
            value,
            locale: AppLocale.resolvedLocale,
            comment: comment
        ))
    }
}
