import Foundation
import Observation
import Synchronization

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

    private var settings: AppSettings

    var language: Language {
        get { Language(rawValue: settings.language) ?? .system }
        set {
            do { try setLanguage(newValue) }
            catch { Log.app.error("AppLocale.save failed error=\(error.localizedDescription)") }
        }
    }

    nonisolated private static let localeLanguage = Mutex<String>(
        (try? AppSettings.load())?.language ?? "system"
    )

    private init() {
        settings = (try? AppSettings.load()) ?? AppSettings()
        Self.localeLanguage.withLock { $0 = settings.language }
        Log.app.info("AppLocale ready language=\(self.language.rawValue) locale=\(self.locale.identifier)")
    }

    func setLanguage(_ language: Language) throws {
        guard try AppSettings.load() == settings else {
            throw StorageMigrationError.collision("app settings changed externally")
        }
        guard language.rawValue != settings.language else { return }
        var next = settings
        next.language = language.rawValue
        try next.save()
        settings = next
        Self.localeLanguage.withLock { $0 = next.language }
        Log.app.info("AppLocale.language -> \(language.rawValue)")
    }

    nonisolated static var resolvedLocale: Locale {
        let stored = localeLanguage.withLock { $0 }
        return stored == "system" ? .current : Locale(identifier: stored)
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
