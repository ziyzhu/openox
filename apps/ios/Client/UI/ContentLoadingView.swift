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
    let secondaryColor: DynamicColor

    init(minHeight: CGFloat = 52, accessibilityIdentifier: String, secondaryColor: DynamicColor = Theme.Colors.onSurfaceMuted) {
        self.minHeight = minHeight
        self.accessibilityIdentifier = accessibilityIdentifier
        self.secondaryColor = secondaryColor
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            CellularAutomatonLoader.mini
            Text("Loading services…")
                .font(Theme.Fonts.bodySm)
        }
        .foregroundStyle(secondaryColor)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading services…"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
