import SwiftUI

struct VoiceSettingsView: View {
    @State private var errorMessage: String?
    private var store: KokoroModelStore { .shared }
    private var mandarinStore: KokoroMandarinModelStore { .shared }

    var body: some View {
        ScrollView {
            SettingsSection("Voice", layout: .group) {
                VStack(spacing: 0) {
                    HStack(spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Heart")
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: KokoroModelStore.expectedBytes, countStyle: .file))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        }
                        Spacer(minLength: 0)
                        voiceAction
                    }
                    .settingsRowPadding()
                    Divider().settingsContentInset()
                    HStack(spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Mandarin")
                                .font(Theme.Fonts.bodyMd)
                                .foregroundStyle(Theme.Colors.onSurface)
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: KokoroMandarinModelStore.expectedBytes, countStyle: .file))
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                        }
                        Spacer(minLength: 0)
                        mandarinAction
                    }
                    .settingsRowPadding()
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.refresh()
            mandarinStore.refresh()
        }
        .onChange(of: store.state) { _, state in
            if case .failed(let message) = state { errorMessage = message }
        }
        .onChange(of: mandarinStore.state) { _, state in
            if case .failed(let message) = state { errorMessage = message }
        }
        .alert("Voice", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var voiceAction: some View {
        switch store.state {
        case .notInstalled, .failed:
            Button { store.download() } label: {
                Image(systemName: "icloud.and.arrow.down")
                    .font(Theme.Icons.md)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Theme.Colors.primary, lineWidth: 1.5))
            }
            .accessibilityLabel("Download Heart voice")
            .accessibilityIdentifier(A11yID.Settings.voiceDownload)
        case .downloading(let fraction):
            Circle()
                .stroke(Theme.Colors.primary.opacity(0.2), lineWidth: 2)
                .overlay {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.Colors.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 32, height: 32)
                .accessibilityLabel("Downloading Heart voice")
                .accessibilityValue("\(Int(fraction * 100))%")
        case .preparing:
            ProgressView()
                .frame(width: 32, height: 32)
                .accessibilityLabel("Preparing Heart voice")
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.Icons.md)
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 32, height: 32)
                .accessibilityLabel("Heart voice ready")
        }
    }

    @ViewBuilder
    private var mandarinAction: some View {
        switch mandarinStore.state {
        case .notInstalled, .failed:
            Button { mandarinStore.download() } label: {
                Image(systemName: "icloud.and.arrow.down")
                    .font(Theme.Icons.md)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().stroke(Theme.Colors.primary, lineWidth: 1.5))
            }
            .accessibilityLabel("Download Mandarin voice")
        case .downloading(let fraction):
            Circle()
                .stroke(Theme.Colors.primary.opacity(0.2), lineWidth: 2)
                .overlay {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.Colors.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 32, height: 32)
                .accessibilityLabel("Downloading Mandarin voice")
                .accessibilityValue("\(Int(fraction * 100))%")
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.Icons.md)
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 32, height: 32)
                .accessibilityLabel("Mandarin voice ready")
        }
    }
}
