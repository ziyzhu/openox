import SwiftUI

struct OnDeviceModelsView: View {
    @State private var errorMessage: String?
    private var store: OnDeviceModelStore { .shared }

    var body: some View {
        ScrollView {
            SettingsSection("Models") {
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Gemma 4 E2B")
                            .font(Theme.Fonts.bodyMd)
                            .foregroundStyle(Theme.Colors.onSurface)
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: OnDeviceModelStore.expectedBytes, countStyle: .file))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Colors.onSurfaceMuted)
                    }
                    Spacer(minLength: 0)
                    modelAction
                }
            }
            .settingsPagePadding()
        }
        .scrollIndicators(.hidden)
        .background(Theme.Colors.background)
        .navigationTitle("On-device models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refresh() }
        .onChange(of: store.state) { _, state in
            if case .failed(let message) = state { errorMessage = message }
        }
        .alert("Model", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var modelAction: some View {
        switch store.state {
        case .notInstalled, .failed:
            Button { store.download() } label: {
                Image(systemName: "icloud.and.arrow.down")
                    .font(Theme.Icons.md)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Download Gemma 4 E2B")
        case .downloading(let fraction):
            if let fraction {
                Circle()
                    .stroke(Theme.Colors.primary.opacity(0.2), lineWidth: 2)
                    .overlay {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Theme.Colors.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Downloading Gemma 4 E2B")
                    .accessibilityValue("\(Int(fraction * 100))%")
            } else {
                ProgressView()
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Downloading Gemma 4 E2B")
            }
        case .verifying:
            ProgressView()
                .frame(width: 32, height: 32)
                .accessibilityLabel("Verifying Gemma 4 E2B")
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.Icons.md)
                .foregroundStyle(Theme.Colors.primary)
                .frame(width: 32, height: 32)
                .accessibilityLabel("Gemma 4 E2B ready")
        }
    }
}
