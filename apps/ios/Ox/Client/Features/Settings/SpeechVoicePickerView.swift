import AVFAudio
import Combine
import Observation
import SwiftUI

struct SpeechVoicePickerView: View {
    @State private var preview = SpeechVoicePreview()

    private var appLocale: AppLocale { .shared }
    private var settings: SpeechVoiceSettings { .shared }
    private var voices: [AVSpeechSynthesisVoice] { settings.availableVoices(for: appLocale.locale) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                voiceRow(
                    name: L10n.string("Automatic"),
                    detail: settings.automaticVoice(for: appLocale.locale).map(voiceDetail),
                    identifier: nil,
                    voice: settings.automaticVoice(for: appLocale.locale)
                )

                ForEach(voices, id: \.identifier) { voice in
                    Divider().settingsContentInset()
                    voiceRow(
                        name: voice.name,
                        detail: voiceDetail(voice),
                        identifier: voice.identifier,
                        voice: voice
                    )
                }
            }
            .settingsSurface()
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings.reloadAvailableVoices(for: appLocale.locale, reason: "pickerAppear")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            settings.reloadAvailableVoices(for: appLocale.locale, reason: "systemChange")
        }
        .onDisappear { preview.stop(reason: "pageDisappear") }
    }

    private func voiceRow(
        name: String,
        detail: String?,
        identifier: String?,
        voice: AVSpeechSynthesisVoice?
    ) -> some View {
        let isSelected = settings.selectedVoice(for: appLocale.locale)?.identifier == identifier
        let optionID = identifier.map(A11yID.Settings.voiceOption) ?? A11yID.Settings.voiceAutomatic
        let previewID = identifier.map(A11yID.Settings.voicePreview) ?? A11yID.Settings.voiceAutomaticPreview
        let playbackID = identifier ?? "automatic"

        return HStack(spacing: Theme.Spacing.sm) {
            Button {
                settings.selectedVoiceIdentifier = identifier
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name)
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                        if let detail {
                            Text(verbatim: detail)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(Theme.Colors.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(optionID)
            .accessibilityValue(isSelected ? L10n.string("Selected") : "")

            Button {
                preview.toggle(text: previewText, voice: voice, identifier: playbackID)
            } label: {
                Image(systemName: preview.speakingIdentifier == playbackID ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Theme.Colors.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.Colors.primary.opacity(0.12)))
                    .minimumTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(preview.speakingIdentifier == playbackID ? "Stop preview" : "Preview voice")
            .accessibilityIdentifier(previewID)
        }
        .padding(.leading, SettingsLayout.horizontalInset)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var previewText: String {
        L10n.string("Hello, this is how I’ll read Ox’s responses.")
    }

    private func voiceDetail(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = appLocale.locale.localizedString(forIdentifier: voice.language) ?? voice.language
        switch voice.quality {
        case .premium:
            return "\(language) · \(L10n.string("Premium"))"
        case .enhanced:
            return "\(language) · \(L10n.string("Enhanced"))"
        default:
            return "\(language) · \(L10n.string("Basic"))"
        }
    }
}

@MainActor
@Observable
private final class SpeechVoicePreview: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    private(set) var speakingIdentifier: String?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let audioSession = AVAudioSession.sharedInstance()
    @ObservationIgnored private let audioSessionID = UUID()
    @ObservationIgnored private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(text: String, voice: AVSpeechSynthesisVoice?, identifier: String) {
        if speakingIdentifier == identifier {
            stop(reason: "toggle")
            return
        }

        stop(reason: "replacement")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        guard activateAudioSession() else { return }
        activeUtterance = utterance
        speakingIdentifier = identifier
        Log.ui.info("SpeechVoice.preview start identifier=\(voice?.identifier ?? "automatic") quality=\(voice?.quality.rawValue ?? 0)")
        synthesizer.speak(utterance)
    }

    func stop(reason: String) {
        guard let speakingIdentifier else { return }
        activeUtterance = nil
        self.speakingIdentifier = nil
        synthesizer.stopSpeaking(at: .immediate)
        deactivateAudioSession(reason: reason)
        Log.ui.info("SpeechVoice.preview stop identifier=\(speakingIdentifier) reason=\(reason)")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance, outcome: "finished")
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance, outcome: "canceled")
    }

    private func finish(_ utterance: AVSpeechUtterance, outcome: String) {
        guard activeUtterance === utterance, let speakingIdentifier else { return }
        activeUtterance = nil
        self.speakingIdentifier = nil
        deactivateAudioSession(reason: outcome)
        Log.ui.info("SpeechVoice.preview \(outcome) identifier=\(speakingIdentifier)")
    }

    private func activateAudioSession() -> Bool {
        do {
            try AppAudioSession.activatePlayback(owner: audioSessionID)
            let route = audioSession.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            Log.ui.info("SpeechVoice.preview audioSession activated category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) route=\(route)")
            return true
        } catch {
            Log.ui.error("SpeechVoice.preview audioSession activation failed error=\(error.localizedDescription)")
            return false
        }
    }

    private func deactivateAudioSession(reason: String) {
        AppAudioSession.deactivate(owner: audioSessionID, reason: "speechVoicePreview.\(reason)")
    }
}
