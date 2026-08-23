import AVFAudio
import Foundation
import Observation

@MainActor
@Observable
final class SpeechVoiceSettings {
    static let shared = SpeechVoiceSettings()

    private(set) var voiceInventory: [AVSpeechSynthesisVoice]

    var selectedVoiceIdentifier: String? {
        didSet {
            guard selectedVoiceIdentifier != oldValue else { return }
            if let selectedVoiceIdentifier {
                UserDefaults.standard.set(selectedVoiceIdentifier, forKey: Self.key)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key)
            }
            Log.ui.info("SpeechVoice.select identifier=\(selectedVoiceIdentifier ?? "automatic")")
        }
    }

    nonisolated private static let key = "speech.voice.identifier"

    private init() {
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: Self.key)
        voiceInventory = AVSpeechSynthesisVoice.speechVoices()
    }

    func availableVoices(for locale: Locale) -> [AVSpeechSynthesisVoice] {
        voiceInventory
            .filter {
                matchesLanguage($0, locale: locale)
                    && $0.quality != .default
                    && !$0.voiceTraits.contains(.isNoveltyVoice)
            }
            .sorted { left, right in
                if left.quality != right.quality {
                    return left.quality.rawValue > right.quality.rawValue
                }
                let normalizedIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
                let leftIsExact = left.language.lowercased() == normalizedIdentifier
                let rightIsExact = right.language.lowercased() == normalizedIdentifier
                if leftIsExact != rightIsExact {
                    return leftIsExact
                }
                if left.name != right.name {
                    return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
                return left.language.localizedStandardCompare(right.language) == .orderedAscending
            }
    }

    func reloadAvailableVoices(for locale: Locale, reason: String) {
        voiceInventory = AVSpeechSynthesisVoice.speechVoices()
        logVoiceInventory(for: locale, reason: reason)
    }

    func selectedVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        guard let selectedVoiceIdentifier else { return nil }
        return availableVoices(for: locale).first { $0.identifier == selectedVoiceIdentifier }
    }

    func preferredVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        selectedVoice(for: locale) ?? automaticVoice(for: locale)
    }

    func automaticVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
        let normalizedIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        let voices = voiceInventory.filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let exact = voices.filter { $0.language.lowercased() == normalizedIdentifier }
        if let voice = highestQuality(in: exact) { return voice }

        let compatible = voices.filter { matchesLanguage($0, locale: locale) }
        return highestQuality(in: compatible) ?? AVSpeechSynthesisVoice(language: locale.identifier)
    }

    func selectedVoiceName(for locale: Locale) -> String {
        selectedVoice(for: locale)?.name ?? L10n.string("Automatic")
    }

    private func matchesLanguage(_ voice: AVSpeechSynthesisVoice, locale: Locale) -> Bool {
        let voiceLanguage = Locale(identifier: voice.language).language
        guard voiceLanguage.languageCode == locale.language.languageCode else { return false }
        guard let requestedScript = locale.language.script, let voiceScript = voiceLanguage.script else { return true }
        return requestedScript == voiceScript
    }

    private func highestQuality(in voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        voices.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    private func logVoiceInventory(for locale: Locale, reason: String) {
        let included = availableVoices(for: locale)
        let languageMatches = voiceInventory.count { matchesLanguage($0, locale: locale) }
        let enhanced = voiceInventory.count { $0.quality == .enhanced }
        let premium = voiceInventory.count { $0.quality == .premium }
        let novelty = voiceInventory.count { $0.voiceTraits.contains(.isNoveltyVoice) }
        let personal = voiceInventory.count { $0.voiceTraits.contains(.isPersonalVoice) }
        Log.ui.info("SpeechVoice.inventory summary reason=\(reason) locale=\(locale.identifier) total=\(voiceInventory.count) languageMatches=\(languageMatches) enhanced=\(enhanced) premium=\(premium) novelty=\(novelty) personal=\(personal) included=\(included.count)")
        for voice in voiceInventory.sorted(by: { $0.identifier < $1.identifier }) {
            let languageMatch = matchesLanguage(voice, locale: locale)
            let highQuality = voice.quality != .default
            let novelty = voice.voiceTraits.contains(.isNoveltyVoice)
            let personal = voice.voiceTraits.contains(.isPersonalVoice)
            let decision = languageMatch && highQuality && !novelty ? "included" : "excluded"
            Log.ui.info("SpeechVoice.inventory voice identifier=\(voice.identifier) name=\(voice.name) language=\(voice.language) quality=\(qualityName(voice.quality)) novelty=\(novelty) personal=\(personal) languageMatch=\(languageMatch) decision=\(decision)")
        }
    }

    private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: "basic"
        case .enhanced: "enhanced"
        case .premium: "premium"
        @unknown default: "unknown(\(quality.rawValue))"
        }
    }
}
