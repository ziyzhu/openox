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

    var responseLanguage: JSONValue {
        Self.responseLanguage(for: locale)
    }

    nonisolated static var resolvedResponseLanguage: JSONValue {
        responseLanguage(for: resolvedLocale)
    }

    nonisolated private static func responseLanguage(for resolved: Locale) -> JSONValue {
        guard let code = resolved.language.languageCode?.identifier, code != "en" else { return .null }
        let name = Locale(identifier: "en").localizedString(forIdentifier: resolved.identifier) ?? resolved.identifier
        return .object(["identifier": .string(resolved.identifier), "name": .string(name)])
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
