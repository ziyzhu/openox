import SwiftUI

struct ContentLoadingView: View {
    let label: LocalizedStringKey

    @State private var showsLabel = false

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader()
            Text(label)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .opacity(showsLabel ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: Theme.Animation.standard)) {
                showsLabel = true
            }
        }
    }
}

struct MonoRepositoryLoadingStatus: View {
    let minHeight: CGFloat
    let accessibilityIdentifier: String

    init(minHeight: CGFloat = 52, accessibilityIdentifier: String) {
        self.minHeight = minHeight
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader.mini
            Text("Loading plugins…")
                .font(Theme.Fonts.bodySm)
        }
        .foregroundStyle(Theme.Colors.onSurfaceMuted)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading plugins…"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
