import SwiftUI

struct ContentLoadingView: View {
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader()
            Text(label)
                .font(Theme.Fonts.bodySm)
                .foregroundStyle(Theme.Colors.onSurfaceMuted)
                .revealed(after: .milliseconds(700))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
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
            Text("Loading services…")
                .font(Theme.Fonts.bodySm)
        }
        .foregroundStyle(Theme.Colors.onSurfaceMuted)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading services…"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
